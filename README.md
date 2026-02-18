# RawViewer

A high-performance RAW image viewer built with Flutter and LibRaw.

This project demonstrates how to integrate C++ libraries (specifically LibRaw) into a Flutter application using `dart:ffi` for efficient image processing. It supports viewing thumbnails and full-resolution previews of various RAW formats (CR2, NEF, ARW, DNG, etc.).

## Features

- **Fast RAW Decoding**: Utilizes LibRaw C++ library for robust and speedy RAW image processing.
- **Thumbnail Grid**: Quickly browse through directories of RAW images.
- **Full Preview**: View high-quality previews of selected images.
- **Native Integration**: Seamless communication between Dart and C++ via FFI.
- **Worker Isolates**: Offloads heavy image processing to background threads to keep the UI responsive.

## Supported Platforms

Currently, the project is configured and tested primarily for **Windows**.
- **Windows**: Full support with bundled LibRaw build configuration.
- **Linux/macOS**: Requires manual configuration of `native_lib` build (PRs welcome!).

## Prerequisites

- [Flutter SDK](https://flutter.dev/docs/get-started/install) (3.2.3 or higher recommended)
- **Windows Development Requirements**:
  - Visual Studio 2019 or later with "Desktop development with C++" workload installed.
  - CMake (included with Visual Studio or installed separately).

## Getting Started

1.  **Clone the repository:**
    ```bash
    git clone https://github.com/yourusername/rawviewer.git
    cd rawviewer
    ```

2.  **Install dependencies:**
    ```bash
    flutter pub get
    ```

3.  **Run the application (Windows):**
    ```bash
    flutter run -d windows
    ```
    *Note: The first run might take a while as it compiles the LibRaw C++ library.*

## Project Structure

- `lib/`: Dart source code (UI, Logic, FFI bindings).
  - `native_lib.dart`: FFI definitions and bindings to the C++ library.
  - `worker_service.dart`: Handles background processing tasks.
- `windows/native_lib/`: C++ source code and CMake configuration for the native library.
  - `libraw/`: Embedded LibRaw source code.
  - `wrapper.cpp`: C-style wrapper functions exposed to Dart.
- `libraw_src/`: Upstream LibRaw source (reference).

## License

This project uses [LibRaw](https://www.libraw.org/), which is dual-licensed under LGPL 2.1 and CDDL 1.0.
Please ensure you comply with LibRaw's licensing terms when distributing this application.

## Acknowledgments

- [LibRaw](https://www.libraw.org/) - For the awesome RAW decoding library.
- [Flutter](https://flutter.dev/) - For the beautiful UI framework.
