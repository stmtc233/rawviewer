# Raw Viewer

![Flutter](https://img.shields.io/badge/Flutter-%2302569B.svg?style=for-the-badge&logo=Flutter&logoColor=white)

*[Read this in Chinese / 中文文档](README_zh.md)*

A fast, cross-platform image viewer specifically built for RAW photography files, developed with Flutter and powered by [LibRaw](https://www.libraw.org/) via Dart FFI. 

Raw Viewer allows photographers and enthusiasts to seamlessly view, browse, and organize their camera RAW files alongside standard image formats without relying on heavy photo editing software.

## Features

- **Extensive Format Support:**
  - RAW formats: `.arw`, `.cr2`, `.cr3`, `.dng`, `.nef`, `.orf`, `.raf`, `.rw2`, `.srw`
  - Standard formats: `.jpg`, `.jpeg`, `.png`, `.webp`
- **Blazing Fast Decoding:** Uses native C++ `LibRaw` with Dart isolates to decode images off the main UI thread.
- **Embedded Previews:** Extracts embedded thumbnails and previews for lightning-fast browsing before falling back to full RAW decoding.
- **Smart Caching:** Built-in LRU cache to manage memory efficiency while keeping viewed images ready.
- **EXIF Metadata:** Reads and displays true image capture timestamps directly from EXIF data.
- **Smooth Interaction:** Fast page scroll, smooth pinch-to-zoom (touch), and scroll-to-zoom (mouse) functionality.
- **Cross-Platform:** Built for desktop (Windows, macOS) and mobile (Android) natively.

## Screenshots

*(Add screenshots here)*

## Getting Started

### Prerequisites

- [Flutter SDK](https://flutter.dev/docs/get-started/install) (>= 3.2.3)
- Appropriate native build tools for your target platform:
  - **Windows:** Visual Studio with C++ workload
  - **macOS/iOS:** Xcode
  - **Android:** Android Studio & NDK

### Installation

1. Clone the repository:
   ```bash
   git clone https://github.com/stmtc233/rawviewer.git
   cd rawviewer
   ```

2. Fetch Flutter dependencies:
   ```bash
   flutter pub get
   ```

3. Run the application:
   ```bash
   flutter run
   ```

## Architecture

- **Frontend:** Flutter framework with a grid-based gallery and swipeable full-screen viewer.
- **Backend Decoder:**
  - Uses `ffi` to connect Dart with native C/C++ wrappers around LibRaw.
  - Native wrappers extract thumbnails and half-size previews efficiently.
  - Generates standard BMP bytes in memory for instant rendering via `Image.memory`.
- **Isolate Workers:** All intensive C++ FFI calls are offloaded using Dart compute/worker services to prevent UI jank.

## Dependencies

- [file_picker](https://pub.dev/packages/file_picker) - For opening files and folders natively.
- [exif](https://pub.dev/packages/exif) - To parse image metadata timestamps.
- [permission_handler](https://pub.dev/packages/permission_handler) - Handling Android storage permissions.
- [ffi](https://pub.dev/packages/ffi) - For LibRaw C++ bindings.

## License

This project is licensed under the [MIT License](LICENSE).

**Third-Party Licenses:**
- This software uses the [LibRaw](https://www.libraw.org/) library, which is distributed under the **GNU LESSER GENERAL PUBLIC LICENSE version 2.1 (LGPL-2.1)** and the **COMMON DEVELOPMENT AND DISTRIBUTION LICENSE (CDDL) Version 1.0**. 
- LibRaw is dynamically linked and used via Dart FFI. The original LibRaw source code is included in this repository unmodified. You can choose either LGPL-2.1 or CDDL-1.0 to comply with LibRaw's usage requirements.
