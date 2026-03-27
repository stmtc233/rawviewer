#include "flutter_window.h"

#include <commctrl.h>
#include <optional>
#include <shellapi.h>
#include <set>

#include "flutter/generated_plugin_registrant.h"
#include <flutter/standard_method_codec.h>

#include "utils.h"

namespace {

constexpr char kOpenPathChannelName[] = "rawviewer/open_paths";
constexpr UINT_PTR kFlutterContentWindowSubclassId = 1;

flutter::EncodableList EncodePaths(const std::vector<std::string>& paths) {
  flutter::EncodableList encoded_paths;
  for (const auto& open_path : paths) {
    encoded_paths.emplace_back(open_path);
  }
  return encoded_paths;
}

std::vector<std::string> NormalizePaths(const std::vector<std::string>& paths) {
  std::set<std::string> seen;
  std::vector<std::string> normalized_paths;

  for (const auto& open_path : paths) {
    if (open_path.empty()) {
      continue;
    }
    if (seen.insert(open_path).second) {
      normalized_paths.push_back(open_path);
    }
  }

  return normalized_paths;
}

std::vector<std::string> ExtractDroppedPaths(HDROP drop) {
  UINT file_count = DragQueryFileW(drop, 0xFFFFFFFF, nullptr, 0);
  std::vector<std::string> paths;
  paths.reserve(file_count);

  for (UINT index = 0; index < file_count; ++index) {
    UINT path_length = DragQueryFileW(drop, index, nullptr, 0);
    std::wstring path(path_length + 1, L'\0');
    DragQueryFileW(drop, index, path.data(), path_length + 1);
    path.resize(path_length);

    std::string utf8_path = Utf8FromUtf16(path.c_str());
    if (!utf8_path.empty()) {
      paths.push_back(std::move(utf8_path));
    }
  }

  return NormalizePaths(paths);
}

}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project,
                             std::vector<std::string> initial_open_paths)
    : project_(project),
      pending_open_paths_(NormalizePaths(initial_open_paths)) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  SetChildContent(flutter_controller_->view()->GetNativeWindow());
  ConfigureOpenPathChannel();

  DragAcceptFiles(GetHandle(), TRUE);
  flutter_content_window_ = flutter_controller_->view()->GetNativeWindow();
  if (flutter_content_window_ != nullptr) {
    DragAcceptFiles(flutter_content_window_, TRUE);
    SetWindowSubclass(flutter_content_window_, FlutterViewWindowProc,
                      kFlutterContentWindowSubclassId,
                      reinterpret_cast<DWORD_PTR>(this));
  }

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  if (flutter_content_window_ != nullptr) {
    RemoveWindowSubclass(flutter_content_window_, FlutterViewWindowProc,
                         kFlutterContentWindowSubclassId);
    DragAcceptFiles(flutter_content_window_, FALSE);
    flutter_content_window_ = nullptr;
  }
  if (GetHandle() != nullptr) {
    DragAcceptFiles(GetHandle(), FALSE);
  }
  open_path_channel_ = nullptr;
  open_path_listener_ready_ = false;

  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_DROPFILES:
      HandleDropFiles(reinterpret_cast<HDROP>(wparam));
      return 0;

    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}

LRESULT CALLBACK FlutterWindow::FlutterViewWindowProc(
    HWND hwnd, UINT message, WPARAM wparam, LPARAM lparam,
    UINT_PTR subclass_id, DWORD_PTR ref_data) {
  auto* that = reinterpret_cast<FlutterWindow*>(ref_data);
  if (that != nullptr && message == WM_DROPFILES) {
    that->HandleDropFiles(reinterpret_cast<HDROP>(wparam));
    return 0;
  }

  return DefSubclassProc(hwnd, message, wparam, lparam);
}

void FlutterWindow::ConfigureOpenPathChannel() {
  open_path_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(), kOpenPathChannelName,
          &flutter::StandardMethodCodec::GetInstance());

  open_path_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) {
        if (call.method_name() == "getInitialPaths") {
          open_path_listener_ready_ = true;
          result->Success(
              flutter::EncodableValue(EncodePaths(ConsumePendingOpenPaths())));
          return;
        }

        result->NotImplemented();
      });
}

void FlutterWindow::HandleDropFiles(HDROP drop) {
  const std::vector<std::string> dropped_paths = ExtractDroppedPaths(drop);
  DragFinish(drop);
  HandleOpenPaths(dropped_paths);
}

void FlutterWindow::HandleOpenPaths(const std::vector<std::string>& paths) {
  const std::vector<std::string> normalized_paths = NormalizePaths(paths);
  if (normalized_paths.empty()) {
    return;
  }

  if (!open_path_listener_ready_ || open_path_channel_ == nullptr) {
    pending_open_paths_.insert(pending_open_paths_.end(),
                               normalized_paths.begin(),
                               normalized_paths.end());
    pending_open_paths_ = NormalizePaths(pending_open_paths_);
    return;
  }

  open_path_channel_->InvokeMethod(
      "openPaths",
      std::make_unique<flutter::EncodableValue>(EncodePaths(normalized_paths)));
}

std::vector<std::string> FlutterWindow::ConsumePendingOpenPaths() {
  std::vector<std::string> pending_paths = NormalizePaths(pending_open_paths_);
  pending_open_paths_.clear();
  return pending_paths;
}
