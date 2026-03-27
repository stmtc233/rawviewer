# Raw Viewer

![Flutter](https://img.shields.io/badge/Flutter-%2302569B.svg?style=for-the-badge&logo=Flutter&logoColor=white)

*[Read this in English](README.md)*

一个基于 Flutter 开发的快速、跨平台的相机 RAW 格式图片浏览器。底层通过 Dart FFI 集成了 [LibRaw](https://www.libraw.org/) 用于高性能的 RAW 解码。

Raw Viewer 旨在为摄影师和摄影爱好者提供一个轻量、流畅的工具，让你无需打开庞大的后期处理软件，即可轻松浏览和整理相机 RAW 文件及常规格式图片。

## 功能特性

- **广泛的格式支持:**
  - RAW 格式: `.arw`, `.cr2`, `.cr3`, `.dng`, `.nef`, `.orf`, `.raf`, `.rw2`, `.srw`
  - 常规格式: `.jpg`, `.jpeg`, `.png`, `.webp`
- **极速解码:** 结合原生 C++ `LibRaw` 与 Dart Isolate（多线程），将图像解码过程转移至后台，确保 UI 流畅无卡顿。
- **内嵌预览:** 优先提取 RAW 文件中内嵌的缩略图和预览图，实现极速翻页浏览，并支持一键切换至完整的 RAW 原图解码。
- **智能缓存:** 内置 LRU 缓存机制，动态管理内存，兼顾浏览速度与内存占用。
- **EXIF 元数据:** 自动读取并显示 EXIF 中的真实拍摄时间。
- **流畅交互:** 支持顺滑的快速翻页，并适配了触屏的捏合缩放（Pinch-to-zoom）与鼠标滚轮缩放。
- **跨平台支持:** 原生支持桌面端 (Windows, macOS) 与移动端 (Android)。

## 界面截图

*(在此处添加截图)*

## 快速开始

### 环境依赖

- [Flutter SDK](https://flutter.dev/docs/get-started/install) (>= 3.2.3)
- 对应目标平台的原生编译工具:
  - **Windows:** Visual Studio (包含 C++ 桌面开发工作负载)
  - **macOS/iOS:** Xcode
  - **Android:** Android Studio 及 NDK

### 安装与运行

1. 克隆代码仓库:
   ```bash
   git clone https://github.com/stmtc233/rawviewer.git
   cd rawviewer
   ```

2. 获取 Flutter 依赖包:
   ```bash
   flutter pub get
   ```

3. 运行应用:
   ```bash
   flutter run
   ```

## 技术架构

- **前端:** 使用 Flutter 框架，包含网格画廊与全屏手势滑动预览页面。
- **解码引擎:**
  - 通过 `ffi` 连接 Dart 与封装了 LibRaw 的原生 C/C++ 动态库。
  - 原生层高效提取缩略图及半尺寸（Half-size）预览图。
  - 在内存中直接生成标准 BMP 字节流，并通过 `Image.memory` 极速渲染。
- **异步 Worker:** 所有的 C++ FFI 密集型计算均通过 Dart compute/worker 服务分配至独立线程，杜绝 UI 线程阻塞。

## 主要依赖库

- [file_picker](https://pub.dev/packages/file_picker) - 调起系统原生文件与文件夹选择器。
- [exif](https://pub.dev/packages/exif) - 解析图片 EXIF 拍摄时间。
- [permission_handler](https://pub.dev/packages/permission_handler) - 处理 Android 的存储权限申请。
- [ffi](https://pub.dev/packages/ffi) - 提供与 LibRaw C++ 代码交互的支持。

## 开源协议

本项目（Raw Viewer）本身采用 [MIT 协议](LICENSE) 开源。

**第三方许可说明:**
- 本软件使用了 [LibRaw](https://www.libraw.org/) 库。LibRaw 遵循双重开源许可：**GNU LESSER GENERAL PUBLIC LICENSE version 2.1 (LGPL-2.1)** 与 **COMMON DEVELOPMENT AND DISTRIBUTION LICENSE (CDDL) Version 1.0**。
- 本项目通过 Dart FFI 以动态链接（Dynamic Linking）的方式使用 LibRaw，且未修改其原始源代码。使用者在满足上述两种许可协议之一的条件下即可合法使用。
