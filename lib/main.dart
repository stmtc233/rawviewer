import 'dart:io';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:path/path.dart' as path;
import 'native_lib.dart';
import 'settings_page.dart';
import 'lru_cache.dart';
import 'worker_service.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Raw Viewer',
      theme: ThemeData(
        brightness: Brightness.dark,
        primarySwatch: Colors.blue,
      ),
      home: const HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  String? _currentDir;
  List<String> _files = [];
  // Use LRU Cache to limit memory usage.
  late LruCache<String, LibRawImage> _imageCache;
  ViewerSettings _settings = const ViewerSettings();

  @override
  void initState() {
    super.initState();
    _initCache();
  }

  void _initCache() {
    // maxCacheSize is in MB, convert to bytes
    final int maxBytes = _settings.maxCacheSize * 1024 * 1024;
    _imageCache = LruCache(
      maxBytes,
      sizeOf: (image) => image.data.length,
    );
  }

  Future<void> _openFolder() async {
    if (Platform.isAndroid) {
      // Request permissions for file access
      // For Android 11+ (API 30+)
      if (await Permission.manageExternalStorage.status.isDenied) {
        await Permission.manageExternalStorage.request();
      }
      // For older Android or if generic storage permission is needed
      if (await Permission.storage.status.isDenied) {
        await Permission.storage.request();
      }
    }

    String? selectedDirectory = await FilePicker.platform.getDirectoryPath();

    if (selectedDirectory != null) {
      final dir = Directory(selectedDirectory);
      final List<String> rawExtensions = [
        '.arw',
        '.cr2',
        '.cr3',
        '.dng',
        '.nef',
        '.orf',
        '.raf',
        '.rw2',
        '.srw'
      ];

      final files = dir
          .listSync()
          .where((entity) {
            if (entity is File) {
              final ext = path.extension(entity.path).toLowerCase();
              return rawExtensions.contains(ext);
            }
            return false;
          })
          .map((e) => e.path)
          .toList();

      setState(() {
        _currentDir = selectedDirectory;
        _files = files;
        // Clear cache when changing folders
        _imageCache.clear();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_currentDir ?? 'Raw Viewer'),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings),
            onPressed: () async {
              final result = await Navigator.push<ViewerSettings>(
                context,
                MaterialPageRoute(
                  builder: (context) => SettingsPage(settings: _settings),
                ),
              );

              if (result != null) {
                setState(() {
                  if (_settings.maxCacheSize != result.maxCacheSize) {
                    _settings = result;
                    _initCache(); // Re-initialize with new size
                  } else {
                    _settings = result;
                  }
                });
              }
            },
          ),
          IconButton(
            icon: const Icon(Icons.folder_open),
            onPressed: _openFolder,
          ),
        ],
      ),
      body: _files.isEmpty
          ? const Center(child: Text('Open a folder with RAW images'))
          : GridView.builder(
              // Add cacheExtent to keep a few items off-screen alive
              cacheExtent: 200,
              padding: const EdgeInsets.all(8),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 4,
                crossAxisSpacing: 8,
                mainAxisSpacing: 8,
              ),
              itemCount: _files.length,
              itemBuilder: (context, index) {
                final filePath = _files[index];
                // Use distinct key for thumbnail
                final cacheKey = '$filePath:thumb';
                return RawThumbnail(
                  key: ValueKey(filePath), // Important for recycling
                  filePath: filePath,
                  cachedImage: _imageCache.get(cacheKey),
                  onCacheUpdate: (image) {
                    // Update cache asynchronously
                    Future(() => _imageCache.put(cacheKey, image));
                  },
                  onTap: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (context) => ImagePreviewPage(
                          files: _files,
                          initialIndex: index,
                          imageCache: _imageCache,
                          settings: _settings,
                        ),
                      ),
                    );
                  },
                );
              },
            ),
    );
  }
}

class RawThumbnail extends StatefulWidget {
  final String filePath;
  final LibRawImage? cachedImage;
  final Function(LibRawImage) onCacheUpdate;
  final VoidCallback onTap;

  const RawThumbnail({
    super.key,
    required this.filePath,
    this.cachedImage,
    required this.onCacheUpdate,
    required this.onTap,
  });

  @override
  State<RawThumbnail> createState() => _RawThumbnailState();
}

class _RawThumbnailState extends State<RawThumbnail> {
  WorkerTask<LibRawImage?>? _thumbTask;
  Future<LibRawImage?>? _thumbFuture;

  @override
  void initState() {
    super.initState();
    // Start loading only if not cached
    if (widget.cachedImage == null) {
      _loadThumbnail();
    }
  }

  @override
  void didUpdateWidget(RawThumbnail oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.filePath != oldWidget.filePath) {
      _thumbTask?.cancel();
      _thumbTask = null;
      _thumbFuture = null;

      // If the file path changes (recycling), we need to reload or check cache
      if (widget.cachedImage == null) {
        _loadThumbnail();
      }
    }
  }

  @override
  void dispose() {
    _thumbTask?.cancel();
    super.dispose();
  }

  void _loadThumbnail() {
    final task = WorkerService().requestThumbnail(widget.filePath);
    _thumbTask = task;
    _thumbFuture = task.result.then((image) {
      if (!mounted) return null; // Discard result if widget is disposed
      if (image != null) {
        widget.onCacheUpdate(image);
      }
      return image;
    });
  }

  @override
  Widget build(BuildContext context) {
    Widget child;
    if (widget.cachedImage != null) {
      child = _buildThumbnail(widget.cachedImage!);
    } else {
      child = FutureBuilder<LibRawImage?>(
        future: _thumbFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return Container(
              color: Colors.grey[800],
              child: const Center(
                  child: SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2))),
            );
          }
          if (snapshot.hasError || !snapshot.hasData || snapshot.data == null) {
            return Container(
              color: Colors.grey[800],
              child: const Center(child: Icon(Icons.broken_image, size: 20)),
            );
          }

          return _buildThumbnail(snapshot.data!);
        },
      );
    }

    return Semantics(
      label: path.basename(widget.filePath),
      button: true,
      onTap: widget.onTap,
      excludeSemantics: true,
      child: GestureDetector(
        onTap: widget.onTap,
        child: child,
      ),
    );
  }

  Widget _buildThumbnail(LibRawImage rawImage) {
    return GridTile(
      footer: GridTileBar(
        backgroundColor: Colors.black45,
        title: Text(path.basename(widget.filePath),
            style: const TextStyle(fontSize: 10)),
      ),
      child: RawImageWidget(
        rawImage: rawImage,
        fit: BoxFit.cover,
        memCacheWidth: 100,
        heroTag: widget.filePath,
      ),
    );
  }
}

class ImagePreviewPage extends StatefulWidget {
  final List<String> files;
  final int initialIndex;
  final LruCache<String, LibRawImage> imageCache;
  final ViewerSettings settings;

  const ImagePreviewPage({
    super.key,
    required this.files,
    required this.initialIndex,
    required this.imageCache,
    required this.settings,
  });

  @override
  State<ImagePreviewPage> createState() => _ImagePreviewPageState();
}

class _ImagePreviewPageState extends State<ImagePreviewPage> {
  late PageController _pageController;
  late int _currentIndex;
  late int _targetPage;

  @override
  void initState() {
    super.initState();
    _currentIndex = widget.initialIndex;
    _targetPage = widget.initialIndex;
    _pageController = PageController(initialPage: widget.initialIndex);
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  void _onPageChanged(int index) {
    setState(() {
      _currentIndex = index;
      if ((_targetPage - index).abs() <= 1) {
        _targetPage = index;
      }
    });
  }

  void _switchPage(int delta) {
    // Accumulate target
    int newTarget = _targetPage + delta;
    // Clamp
    if (newTarget < 0) newTarget = 0;
    if (newTarget >= widget.files.length) newTarget = widget.files.length - 1;

    if (newTarget != _targetPage) {
      _targetPage = newTarget;
      _pageController.animateToPage(
        _targetPage,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOutCubic,
      );
    } else if (newTarget != _currentIndex) {
      // If we are stuck (target == current limit) but current is not there yet, animate
      _pageController.animateToPage(
        newTarget,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOutCubic,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final currentFilePath = widget.files[_currentIndex];
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          PageView.builder(
            controller: _pageController,
            allowImplicitScrolling: true,
            itemCount: widget.files.length,
            onPageChanged: _onPageChanged,
            itemBuilder: (context, index) {
              final filePath = widget.files[index];
              return SingleImagePreview(
                key: ValueKey(filePath),
                filePath: filePath,
                thumbnail: widget.imageCache.get('$filePath:thumb'),
                imageCache: widget.imageCache,
                settings: widget.settings,
                onSwitchRequest: _switchPage,
                isActive: index == _currentIndex,
              );
            },
          ),
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: AppBar(
              title: Text(path.basename(currentFilePath)),
              backgroundColor: Colors.transparent,
              elevation: 0,
            ),
          ),
        ],
      ),
    );
  }
}

class SingleImagePreview extends StatefulWidget {
  final String filePath;
  final LibRawImage? thumbnail;
  final LruCache<String, LibRawImage> imageCache;
  final ViewerSettings settings;
  final Function(int) onSwitchRequest;
  final bool isActive;

  const SingleImagePreview({
    super.key,
    required this.filePath,
    this.thumbnail,
    required this.imageCache,
    required this.settings,
    required this.onSwitchRequest,
    required this.isActive,
  });

  @override
  State<SingleImagePreview> createState() => _SingleImagePreviewState();
}

class _SingleImagePreviewState extends State<SingleImagePreview> {
  LibRawImage? _thumbnail;
  LibRawImage? _preview;
  bool _isLoadingPreview = false;
  late bool _useEmbeddedPreview;
  late int _halfSize;
  final TransformationController _transformationController =
      TransformationController();
  bool _panEnabled = false;
  // InteractiveViewer scaleEnabled defaults to true.
  // We want to disable it for Mouse (to prevent default zoom on scroll)
  // but keep it enabled for Touch (pinch zoom).
  bool _scaleEnabled = false;

  @override
  void initState() {
    super.initState();
    _thumbnail = widget.thumbnail;
    _useEmbeddedPreview = widget.settings.useEmbeddedPreview;
    _halfSize = widget.settings.halfSize ? 1 : 0;
    _loadImages();
    _transformationController.addListener(_onTransformationChange);
  }

  @override
  void didUpdateWidget(SingleImagePreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.isActive && oldWidget.isActive) {
      _transformationController.value = Matrix4.identity();
    }
    // If we become active, upgrade priority if not fully loaded
    if (widget.isActive && !oldWidget.isActive) {
      // If a low-priority task is running, cancel it so we can restart with high priority
      if (_currentTask != null) {
        _currentTask!.cancel();
        _currentTask = null;
        _isLoadingPreview = false;
      }
      // Reload logic will skip if _thumbnail/_preview are already set,
      // but if we were waiting on a low-priority task, we restart it as high.
      _loadImages();
    }
  }

  WorkerTask<LibRawImage?>? _currentTask;

  @override
  void dispose() {
    _currentTask?.cancel();
    _transformationController.removeListener(_onTransformationChange);
    _transformationController.dispose();
    super.dispose();
  }

  void _onTransformationChange() {
    final scale = _transformationController.value.getMaxScaleOnAxis();
    final newPanEnabled = scale > 1.01; // Small epsilon
    if (_panEnabled != newPanEnabled) {
      setState(() {
        _panEnabled = newPanEnabled;
      });
    }
  }

  Future<void> _loadImages() async {
    // Only load if active to prevent preloading
    if (!widget.isActive) return;

    const priority = TaskPriority.high;

    if (_thumbnail == null) {
      final task =
          WorkerService().requestThumbnail(widget.filePath, priority: priority);
      _currentTask = task;
      final thumb = await task.result;
      _currentTask = null;

      if (mounted && thumb != null) {
        setState(() {
          _thumbnail = thumb;
        });
      }
    }

    if (_useEmbeddedPreview) return;
    if (_preview != null) return;

    // Check cache for preview
    final previewKey = '${widget.filePath}:preview:$_halfSize';
    final cachedPreview = widget.imageCache.get(previewKey);
    if (cachedPreview != null) {
      setState(() {
        _preview = cachedPreview;
      });
      return;
    }

    if (mounted) {
      setState(() {
        _isLoadingPreview = true;
      });
    }

    final task = WorkerService().requestPreview(widget.filePath,
        halfSize: _halfSize, priority: priority);
    _currentTask = task;
    final preview = await task.result;
    _currentTask = null;

    if (mounted) {
      setState(() {
        _preview = preview;
        _isLoadingPreview = false;
      });
      if (preview != null) {
        // Run cache update asynchronously to avoid blocking UI or subsequent tasks
        Future(() => widget.imageCache.put(previewKey, preview));
      }
    }
  }

  void _togglePreviewMode() {
    setState(() {
      _useEmbeddedPreview = !_useEmbeddedPreview;
    });
    if (!_useEmbeddedPreview && _preview == null) {
      _loadImages();
    }
  }

  void _handlePointerSignal(PointerSignalEvent event) {
    if (event is PointerScrollEvent) {
      final keysPressed = HardwareKeyboard.instance.logicalKeysPressed;
      final isCtrlPressed =
          keysPressed.contains(LogicalKeyboardKey.controlLeft) ||
              keysPressed.contains(LogicalKeyboardKey.controlRight);

      if (isCtrlPressed) {
        // Zoom centered on mouse pointer
        final double scaleChange = event.scrollDelta.dy < 0 ? 1.1 : 0.9;
        final Offset focalPoint = event.localPosition;

        final Matrix4 matrix = _transformationController.value.clone();

        // Translate the matrix to the focal point
        // Apply scaling
        // Translate back
        // matrix = T(f) * S(s) * T(-f) * matrix
        //
        // However, since we are updating the transformation matrix directly,
        // we need to be careful about the order.
        // The transformation matrix T maps points from the child's coordinate system to the parent's.
        // We want to scale around a point P in the parent's coordinate system (the viewport).
        // The new matrix T' should satisfy:
        // T'(p) = P + s * (T(p) - P) for a point p in child coordinates mapping to P
        // actually simpler:
        // We want to apply a transformation S centered at P to the current view.
        // M_new = T(P) * S(s) * T(-P) * M_old

        final Matrix4 scaleMatrix = Matrix4.identity()
          ..translate(focalPoint.dx, focalPoint.dy)
          ..scale(scaleChange)
          ..translate(-focalPoint.dx, -focalPoint.dy);

        final Matrix4 newMatrix = scaleMatrix * matrix;

        // Check limits (optional but good)
        // InteractiveViewer handles constraints if we let it, but direct matrix manip might bypass.
        // Let's just apply it.
        _transformationController.value = newMatrix;
      } else {
        // Switch image
        if (event.scrollDelta.dy > 0) {
          widget.onSwitchRequest(1);
        } else if (event.scrollDelta.dy < 0) {
          widget.onSwitchRequest(-1);
        }
      }
    }
  }

  void _onPointerDown(PointerDownEvent event) {
    // If touch, enable scaling (pinch)
    if (event.kind == PointerDeviceKind.touch) {
      if (!_scaleEnabled) {
        setState(() {
          _scaleEnabled = true;
        });
      }
    } else if (event.kind == PointerDeviceKind.mouse) {
      // If mouse click, disable scaling to be safe?
      // Actually mouse drag might need scaleEnabled for panning? No, panEnabled is separate.
      if (_scaleEnabled) {
        setState(() {
          _scaleEnabled = false;
        });
      }
    }
  }

  void _onPointerHover(PointerHoverEvent event) {
    // If mouse hover, disable scaling to prevent wheel zoom
    if (event.kind == PointerDeviceKind.mouse && _scaleEnabled) {
      setState(() {
        _scaleEnabled = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Listener(
          onPointerSignal: _handlePointerSignal,
          onPointerDown: _onPointerDown,
          onPointerHover: _onPointerHover,
          child: Center(
            child: InteractiveViewer(
              transformationController: _transformationController,
              minScale: 1.0, // Prevent zooming out smaller than screen
              maxScale: 5.0,
              panEnabled: _panEnabled,
              scaleEnabled: _scaleEnabled,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  if (_thumbnail != null)
                    // Low-res placeholder (matches grid cache)
                    RawImageWidget(
                      rawImage: _thumbnail!,
                      fit: BoxFit.contain,
                      memCacheWidth: 100, // Match grid cache width
                      heroTag: widget.isActive ? widget.filePath : null,
                    ),
                  if (_thumbnail != null)
                    // High-res version (loads on top)
                    RawImageWidget(
                      rawImage: _thumbnail!,
                      fit: BoxFit.contain,
                    ),
                  if (_preview != null && !_useEmbeddedPreview)
                    RawImageWidget(rawImage: _preview!, fit: BoxFit.contain),
                  if (_thumbnail == null &&
                      (_preview == null || _useEmbeddedPreview))
                    const Center(
                        child: ExcludeSemantics(
                            child: CircularProgressIndicator())),
                  if (_isLoadingPreview &&
                      _preview == null &&
                      !_useEmbeddedPreview)
                    const Center(
                        child: ExcludeSemantics(
                      child: CircularProgressIndicator(
                        valueColor:
                            AlwaysStoppedAnimation<Color>(Colors.white54),
                      ),
                    )),
                ],
              ),
            ),
          ),
        ),
        // Overlay controls
        Positioned(
          top: kToolbarHeight + 20, // Below the main AppBar
          right: 10,
          child: TextButton(
            onPressed: _togglePreviewMode,
            style: TextButton.styleFrom(backgroundColor: Colors.black54),
            child: Text(
              _useEmbeddedPreview ? 'JPG' : 'RAW',
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class RawImageWidget extends StatelessWidget {
  final LibRawImage rawImage;
  final BoxFit? fit;
  final int? memCacheWidth;
  final String? heroTag;

  const RawImageWidget({
    super.key,
    required this.rawImage,
    this.fit,
    this.memCacheWidth,
    this.heroTag,
  });

  @override
  Widget build(BuildContext context) {
    // rawImage.data is now always ready to display (JPEG or BMP)
    // No additional processing needed here.
    Widget image = Image.memory(
      rawImage.data,
      fit: fit,
      cacheWidth: memCacheWidth,
      gaplessPlayback: true,
      errorBuilder: (context, error, stackTrace) => const Center(
        child: Icon(Icons.broken_image, color: Colors.white),
      ),
    );

    if (heroTag != null) {
      return Hero(
        tag: heroTag!,
        child: image,
      );
    }
    return image;
  }
}
