import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:exif/exif.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import 'package:intl/intl.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:path/path.dart' as path;
import 'native_lib.dart';
import 'settings_page.dart';
import 'lru_cache.dart';
import 'worker_service.dart';

const List<String> _rawExtensions = [
  '.arw',
  '.cr2',
  '.cr3',
  '.dng',
  '.nef',
  '.orf',
  '.raf',
  '.rw2',
  '.srw',
];

const List<String> _bitmapExtensions = [
  '.jpg',
  '.jpeg',
  '.png',
  '.webp',
];

const List<String> _supportedExtensions = [
  ..._rawExtensions,
  ..._bitmapExtensions,
];

enum _MediaKind { raw, bitmap }

class _MediaFile {
  final String path;
  final _MediaKind kind;

  const _MediaFile({required this.path, required this.kind});

  bool get isRaw => kind == _MediaKind.raw;
}

final DateFormat _timestampFormatter = DateFormat('yyyy-MM-dd HH:mm:ss');

class _MediaTimestampInfo {
  final DateTime? capturedAt;
  final DateTime modifiedAt;

  const _MediaTimestampInfo({
    required this.capturedAt,
    required this.modifiedAt,
  });

  DateTime getDisplayTime(TimeDisplaySource source) {
    switch (source) {
      case TimeDisplaySource.capturedAt:
        return capturedAt ?? modifiedAt;
      case TimeDisplaySource.modifiedAt:
        return modifiedAt;
    }
  }

  String format(TimeDisplaySource source) {
    return _timestampFormatter.format(getDisplayTime(source));
  }
}

class _TimestampRepository {
  final Map<String, Future<_MediaTimestampInfo>> _futureCache = {};

  Future<_MediaTimestampInfo> load(String filePath) {
    return _futureCache.putIfAbsent(filePath, () => _readTimestampInfo(filePath));
  }

  void clear() {
    _futureCache.clear();
  }

  Future<_MediaTimestampInfo> _readTimestampInfo(String filePath) async {
    final file = File(filePath);
    final stat = await file.stat();
    final modifiedAt = stat.modified;
    DateTime? capturedAt;

    try {
      final bytes = await file.readAsBytes();
      capturedAt = await _parseCapturedAtFromBytes(bytes);
    } catch (_) {
      capturedAt = null;
    }

    return _MediaTimestampInfo(capturedAt: capturedAt, modifiedAt: modifiedAt);
  }
}

Future<DateTime?> _parseCapturedAtFromBytes(Uint8List bytes) async {
  try {
    final data = await readExifFromBytes(bytes);
    final rawValue = data['Image DateTime']?.printable ??
        data['EXIF DateTimeOriginal']?.printable ??
        data['EXIF DateTimeDigitized']?.printable;
    if (rawValue == null || rawValue.isEmpty) {
      return null;
    }
    return _parseExifDateTime(rawValue);
  } catch (_) {
    return null;
  }
}

DateTime? _parseExifDateTime(String value) {
  final normalized = value.trim();
  final exifMatch = RegExp(
    r'^(\d{4}):(\d{2}):(\d{2})[ T](\d{2}):(\d{2}):(\d{2})$',
  ).firstMatch(normalized);
  if (exifMatch != null) {
    return DateTime(
      int.parse(exifMatch.group(1)!),
      int.parse(exifMatch.group(2)!),
      int.parse(exifMatch.group(3)!),
      int.parse(exifMatch.group(4)!),
      int.parse(exifMatch.group(5)!),
      int.parse(exifMatch.group(6)!),
    );
  }
  return DateTime.tryParse(normalized);
}

const MethodChannel _desktopOpenChannel = MethodChannel('rawviewer/open_paths');

enum _OpenedSourceKind { none, folder, files }

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ExcludeSemantics(
      child: MaterialApp(
        title: 'Raw Viewer',
        theme: ThemeData(
          brightness: Brightness.dark,
          primarySwatch: Colors.blue,
        ),
        home: const HomePage(),
      ),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  String? _currentSourceLabel;
  List<_MediaFile> _files = [];
  _OpenedSourceKind _openedSourceKind = _OpenedSourceKind.none;
  // Use LRU Cache to limit memory usage.
  late LruCache<String, ViewerImage> _imageCache;
  final _TimestampRepository _timestampRepository = _TimestampRepository();
  ViewerSettings _settings = const ViewerSettings();

  @override
  void initState() {
    super.initState();
    _initCache();
    unawaited(_listenForDesktopOpenRequests());
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
      await _handleIncomingPaths([selectedDirectory]);
    }
  }

  Future<void> _openFiles() async {
    final result = await FilePicker.platform.pickFiles(
      allowMultiple: true,
      type: FileType.custom,
      allowedExtensions: _supportedExtensions
          .map((extension) => extension.replaceFirst('.', ''))
          .toList(),
    );

    final selectedFiles = result?.paths.whereType<String>().toList();
    if (selectedFiles == null || selectedFiles.isEmpty) {
      return;
    }

    await _handleIncomingPaths(selectedFiles);
  }

  Future<void> _listenForDesktopOpenRequests() async {
    if (!Platform.isMacOS && !Platform.isWindows) {
      return;
    }

    _desktopOpenChannel.setMethodCallHandler((call) async {
      if (call.method != 'openPaths') {
        throw MissingPluginException('Unsupported method: ${call.method}');
      }

      final arguments = call.arguments;
      if (arguments is! List) {
        return;
      }

      await _handleIncomingPaths(arguments.whereType<String>().toList());
    });

    try {
      final initialPaths =
          await _desktopOpenChannel.invokeListMethod<String>('getInitialPaths');
      if (initialPaths != null && initialPaths.isNotEmpty) {
        await _handleIncomingPaths(initialPaths);
      }
    } on MissingPluginException {
      // Ignore when the current platform does not expose desktop open events.
    } on PlatformException {
      // Ignore malformed payloads from the host platform.
    }
  }

  Future<void> _handleIncomingPaths(List<String> incomingPaths) async {
    final normalizedPaths = incomingPaths
        .where((filePath) => filePath.trim().isNotEmpty)
        .map((filePath) => path.normalize(path.absolute(filePath)))
        .toList();
    if (normalizedPaths.isEmpty) {
      return;
    }

    final directories = <String>[];
    final files = <_MediaFile>[];

    for (final openPath in normalizedPaths) {
      final entityType = FileSystemEntity.typeSync(openPath);
      if (entityType == FileSystemEntityType.directory) {
        directories.add(openPath);
        continue;
      }
      if (entityType == FileSystemEntityType.file) {
        final mediaFile = _mediaFileFromPath(openPath);
        if (mediaFile != null) {
          files.add(mediaFile);
        }
      }
    }

    if (directories.isNotEmpty) {
      final directoryFiles = directories.expand(_listRawFilesInDirectory);
      final nextFiles = _deduplicateMediaFiles([...directoryFiles, ...files]);
      _applyOpenedFiles(
        files: nextFiles,
        sourceKind: _OpenedSourceKind.folder,
        title: _folderSelectionTitle(directories),
        clearCache: true,
      );
      return;
    }

    if (files.isEmpty) {
      return;
    }

    final shouldReplaceCurrent = _openedSourceKind != _OpenedSourceKind.files;
    final nextFiles =
        shouldReplaceCurrent ? files : _deduplicateMediaFiles([..._files, ...files]);

    _applyOpenedFiles(
      files: nextFiles,
      sourceKind: _OpenedSourceKind.files,
      title: _fileSelectionTitle(nextFiles.length),
      clearCache: shouldReplaceCurrent,
    );
  }

  void _applyOpenedFiles({
    required List<_MediaFile> files,
    required _OpenedSourceKind sourceKind,
    required String title,
    required bool clearCache,
  }) {
    if (!mounted) {
      return;
    }

    if (clearCache) {
      _imageCache.clear();
      _timestampRepository.clear();
    }

    setState(() {
      _openedSourceKind = sourceKind;
      _currentSourceLabel = title;
      _files = files;
    });
  }

  List<_MediaFile> _listRawFilesInDirectory(String directoryPath) {
    final files = Directory(directoryPath)
        .listSync()
        .whereType<File>()
        .map((file) => _mediaFileFromPath(file.path))
        .whereType<_MediaFile>()
        .toList()
      ..sort((a, b) => a.path.compareTo(b.path));
    return files;
  }

  List<_MediaFile> _deduplicateMediaFiles(Iterable<_MediaFile> files) {
    final seen = <String>{};
    final result = <_MediaFile>[];

    for (final mediaFile in files) {
      final normalizedPath = path.normalize(path.absolute(mediaFile.path));
      if (seen.add(normalizedPath)) {
        result.add(_MediaFile(path: normalizedPath, kind: mediaFile.kind));
      }
    }

    return result;
  }

  _MediaFile? _mediaFileFromPath(String filePath) {
    final normalizedPath = path.normalize(path.absolute(filePath));
    final extension = path.extension(normalizedPath).toLowerCase();
    if (_rawExtensions.contains(extension)) {
      return _MediaFile(path: normalizedPath, kind: _MediaKind.raw);
    }
    if (_bitmapExtensions.contains(extension)) {
      return _MediaFile(path: normalizedPath, kind: _MediaKind.bitmap);
    }
    return null;
  }

  String _folderSelectionTitle(List<String> directories) {
    if (directories.length == 1) {
      return directories.first;
    }
    return '${directories.length} folders';
  }

  String _fileSelectionTitle(int count) {
    return count == 1 ? '1 file' : '$count files';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
        appBar: AppBar(
          title: Text(_currentSourceLabel ?? 'Raw Viewer'),
          actions: [
            IconButton(
              icon: const Icon(Icons.settings),
              onPressed: () async {
                final result = await Navigator.push<ViewerSettings>(
                  context,
                  PageRouteBuilder(
                    opaque: false,
                    barrierColor: Colors.black54,
                    barrierDismissible: true,
                    pageBuilder: (context, animation, secondaryAnimation) {
                      return ExcludeSemantics(
                        child: FadeTransition(
                          opacity: animation,
                          child: Center(
                            child: Container(
                                width: 500,
                                height: 600,
                                clipBehavior: Clip.antiAlias,
                                decoration: BoxDecoration(
                                  color:
                                      Theme.of(context).scaffoldBackgroundColor,
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: SettingsPage(
                                  settings: _settings,
                                  onClose: (res) {
                                    Navigator.pop(context, res);
                                  },
                                )),
                          ),
                        ),
                      );
                    },
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
              icon: const Icon(Icons.file_open),
              onPressed: _openFiles,
            ),
            IconButton(
              icon: const Icon(Icons.folder_open),
              onPressed: _openFolder,
            ),
          ],
        ),
        body: ExcludeSemantics(
          child: _files.isEmpty
              ? const Center(
                  child: Text('Open or drop RAW and image files/folders'),
                )
              : GridView.builder(
                  // Add cacheExtent to keep a few items off-screen alive
                  cacheExtent: 200,
                  padding: const EdgeInsets.all(8),
                  // ... rest of the gridview ...
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 4,
                    crossAxisSpacing: 8,
                    mainAxisSpacing: 8,
                  ),
                  itemCount: _files.length,
                  itemBuilder: (context, index) {
                    final mediaFile = _files[index];
                    final filePath = mediaFile.path;
                    // Use distinct key for thumbnail
                    final cacheKey = '$filePath:thumb';
                    return RawThumbnail(
                      key: ValueKey(filePath), // Important for recycling
                      mediaFile: mediaFile,
                      settings: _settings,
                      timestampRepository: _timestampRepository,
                      cachedImage: _imageCache.get(cacheKey),
                      onCacheUpdate: (image) {
                        // Update cache asynchronously
                        Future(() => _imageCache.put(cacheKey, image));
                      },
                      onTap: () {
                        Navigator.push(
                          context,
                          PageRouteBuilder(
                            pageBuilder:
                                (context, animation, secondaryAnimation) {
                              return ExcludeSemantics(
                                child: FadeTransition(
                                  opacity: animation,
                                  child: ImagePreviewPage(
                                    files: _files,
                                    initialIndex: index,
                                    imageCache: _imageCache,
                                    timestampRepository: _timestampRepository,
                                    settings: _settings,
                                    onClose: () {
                                      Navigator.pop(context);
                                    },
                                  ),
                                ),
                              );
                            },
                          ),
                        );
                      },
                    );
                  },
                ),
        ));
  }
}

class RawThumbnail extends StatefulWidget {
  final _MediaFile mediaFile;
  final ViewerSettings settings;
  final _TimestampRepository timestampRepository;
  final ViewerImage? cachedImage;
  final Function(ViewerImage) onCacheUpdate;
  final VoidCallback onTap;

  const RawThumbnail({
    super.key,
    required this.mediaFile,
    required this.settings,
    required this.timestampRepository,
    this.cachedImage,
    required this.onCacheUpdate,
    required this.onTap,
  });

  String get filePath => mediaFile.path;

  @override
  State<RawThumbnail> createState() => _RawThumbnailState();
}

class _RawThumbnailState extends State<RawThumbnail> {
  WorkerTask<LibRawImage?>? _thumbTask;
  Future<ViewerImage?>? _thumbFuture;
  late Future<_MediaTimestampInfo> _timestampFuture;

  @override
  void initState() {
    super.initState();
    // Start loading only if not cached
    if (widget.cachedImage == null) {
      _loadThumbnail();
    }
    _timestampFuture = widget.timestampRepository.load(widget.filePath);
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
      _timestampFuture = widget.timestampRepository.load(widget.filePath);
    } else if (widget.settings.timeDisplaySource !=
        oldWidget.settings.timeDisplaySource) {
      setState(() {});
    }
  }

  @override
  void dispose() {
    _thumbTask?.cancel();
    super.dispose();
  }

  void _loadThumbnail() {
    if (!widget.mediaFile.isRaw) {
      _thumbFuture = Future<ViewerImage?>(() async {
        final bytes = await File(widget.filePath).readAsBytes();
        final image = ViewerImage.fromEncodedBytes(bytes);
        if (mounted) {
          widget.onCacheUpdate(image);
        }
        return image;
      });
      return;
    }

    final task = WorkerService().requestThumbnail(widget.filePath);
    _thumbTask = task;
    _thumbFuture = task.result.then((image) {
      if (!mounted) return null;
      if (image == null) {
        return null;
      }
      final viewerImage = ViewerImage.fromRaw(image);
      widget.onCacheUpdate(viewerImage);
      return viewerImage;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: path.basename(widget.filePath),
      button: true,
      onTap: widget.onTap,
      child: ExcludeSemantics(
        child: GestureDetector(
          onTap: widget.onTap,
          child: GridTile(
            footer: Container(
              color: Colors.black45,
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    path.basename(widget.filePath),
                    style: const TextStyle(
                      fontSize: 10,
                      height: 1.05,
                      color: Colors.white,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  FutureBuilder<_MediaTimestampInfo>(
                    future: _timestampFuture,
                    builder: (context, snapshot) {
                      final text = snapshot.hasData
                          ? snapshot.data!
                              .format(widget.settings.timeDisplaySource)
                          : '---- -- -- --:--:--';
                      return Text(
                        text,
                        style: const TextStyle(
                          fontSize: 9,
                          height: 1.0,
                          color: Colors.white70,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      );
                    },
                  ),
                ],
              ),
            ),
            child: Stack(
              fit: StackFit.expand,
              children: [
                _buildContent(),
                if (widget.mediaFile.isRaw)
                  Positioned(
                    top: 8,
                    right: 8,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.28),
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: const Text(
                        'RAW',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 10,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.3,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildContent() {
    if (widget.cachedImage != null) {
      return RawImageWidget(
        image: widget.cachedImage!,
        fit: BoxFit.cover,
        memCacheWidth: 100,
        heroTag: widget.filePath,
      );
    }

    return FutureBuilder<ViewerImage?>(
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

        return RawImageWidget(
          image: snapshot.data!,
          fit: BoxFit.cover,
          memCacheWidth: 100,
          heroTag: widget.filePath,
        );
      },
    );
  }
}

class ImagePreviewPage extends StatefulWidget {
  final List<_MediaFile> files;
  final int initialIndex;
  final LruCache<String, ViewerImage> imageCache;
  final _TimestampRepository timestampRepository;
  final ViewerSettings settings;
  final VoidCallback onClose;

  const ImagePreviewPage({
    super.key,
    required this.files,
    required this.initialIndex,
    required this.imageCache,
    required this.timestampRepository,
    required this.settings,
    required this.onClose,
  });

  @override
  State<ImagePreviewPage> createState() => _ImagePreviewPageState();
}

class _ImagePreviewPageState extends State<ImagePreviewPage> {
  late PageController _pageController;
  late int _currentIndex;
  late int _targetPage;
  bool _isLocked = false;

  DateTime? _lastSwitchTime;
  Timer? _scrollStopTimer;
  bool _isFastScrolling = false;
  late Future<_MediaTimestampInfo> _currentTimestampFuture;

  @override
  void initState() {
    super.initState();
    _currentIndex = widget.initialIndex;
    _targetPage = widget.initialIndex;
    _pageController = PageController(initialPage: widget.initialIndex);
    _currentTimestampFuture =
        widget.timestampRepository.load(widget.files[_currentIndex].path);
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  void _onPageChanged(int index) {
    setState(() {
      _currentIndex = index;
      _currentTimestampFuture =
          widget.timestampRepository.load(widget.files[_currentIndex].path);
      if ((_targetPage - index).abs() <= 1) {
        _targetPage = index;
      }
    });

    // We also preload here to cover cases where user swiped manually instead of mouse wheel
    _preloadThumbnails(index);
  }

  void _preloadThumbnails(int centerIndex, {bool isFastScrolling = false}) {
    int range = isFastScrolling ? 2 : 10;
    for (int i = 1; i <= range; i++) {
      _preloadIndex(centerIndex + i);
      _preloadIndex(centerIndex - i);
    }
  }

  void _preloadIndex(int index) {
    if (index >= 0 && index < widget.files.length) {
      final mediaFile = widget.files[index];
      final String filePath = mediaFile.path;
      final thumbKey = '$filePath:thumb';
      if (widget.imageCache.get(thumbKey) == null) {
        if (mediaFile.isRaw) {
          WorkerService()
              .requestThumbnail(filePath, priority: TaskPriority.low)
              .result
              .then((thumb) {
            if (thumb != null) {
              widget.imageCache.put(thumbKey, ViewerImage.fromRaw(thumb));
            }
          });
        } else {
          File(filePath).readAsBytes().then((bytes) {
            widget.imageCache.put(thumbKey, ViewerImage.fromEncodedBytes(bytes));
          });
        }
      }
    }
  }

  void _switchPage(int delta) {
    int newTarget = _targetPage + delta;
    if (newTarget < 0) newTarget = 0;
    if (newTarget >= widget.files.length) newTarget = widget.files.length - 1;

    if (newTarget == _targetPage && newTarget == _currentIndex) {
      return;
    }

    bool isAnimating = false;
    if (_pageController.position.haveDimensions) {
      final page = _pageController.page!;
      if ((page - page.round()).abs() > 0.05) {
        isAnimating = true;
      }
    }

    final now = DateTime.now();
    bool fastScroll = isAnimating ||
        (_lastSwitchTime != null &&
            now.difference(_lastSwitchTime!).inMilliseconds < 400);
    _lastSwitchTime = now;

    _targetPage = newTarget;
    // Preload thumbnails IMMEDIATELY on scroll intention, rather than waiting for animation to hit 50%
    _preloadThumbnails(_targetPage,
        isFastScrolling: fastScroll || _isFastScrolling);

    void startFastScrollTimer() {
      if (!_isFastScrolling) {
        setState(() {
          _isFastScrolling = true;
        });
      }
      _scrollStopTimer?.cancel();
      _scrollStopTimer = Timer(const Duration(milliseconds: 300), () {
        if (mounted) {
          setState(() {
            _isFastScrolling = false;
            // Also ensure we correctly update target/index when stopping
            if (_pageController.page != _targetPage.toDouble()) {
              _pageController.jumpToPage(_targetPage);
            }
          });
        }
      });
    }

    if (fastScroll || _isFastScrolling) {
      startFastScrollTimer();
      _pageController.jumpToPage(_targetPage);
    } else {
      _pageController.animateToPage(
        _targetPage,
        duration: const Duration(milliseconds: 150),
        curve: Curves.easeOut,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final currentFilePath = widget.files[_currentIndex].path;
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          PageView.builder(
            controller: _pageController,
            physics: _isLocked
                ? const NeverScrollableScrollPhysics()
                : const FastPageScrollPhysics(),
            allowImplicitScrolling: true,
            padEnds: true,
            itemCount: widget.files.length,
            onPageChanged: _onPageChanged,
            itemBuilder: (context, index) {
              final mediaFile = widget.files[index];
              final filePath = mediaFile.path;
              return SingleImagePreview(
                key: ValueKey(filePath),
                mediaFile: mediaFile,
                thumbnail: widget.imageCache.get('$filePath:thumb'),
                imageCache: widget.imageCache,
                settings: widget.settings,
                onSwitchRequest: _switchPage,
                isActive: index == _currentIndex,
                isFastScrolling: _isFastScrolling,
                onScaleStateChanged: (isScaling) {
                  if (_isLocked != isScaling) {
                    setState(() {
                      _isLocked = isScaling;
                    });
                  }
                },
              );
            },
          ),
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: FutureBuilder<_MediaTimestampInfo>(
              future: _currentTimestampFuture,
              builder: (context, snapshot) {
                final timestampText = snapshot.hasData
                    ? snapshot.data!.format(widget.settings.timeDisplaySource)
                    : '---- -- -- --:--:--';
                return AppBar(
                  title: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(path.basename(currentFilePath)),
                      Text(
                        timestampText,
                        style: const TextStyle(
                          fontSize: 13,
                          color: Colors.white70,
                        ),
                      ),
                    ],
                  ),
                  backgroundColor: Colors.transparent,
                  elevation: 0,
                  leading: IconButton(
                    icon: const Icon(Icons.arrow_back),
                    onPressed: widget.onClose,
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class SingleImagePreview extends StatefulWidget {
  final _MediaFile mediaFile;
  final ViewerImage? thumbnail;
  final LruCache<String, ViewerImage> imageCache;
  final ViewerSettings settings;
  final Function(int) onSwitchRequest;
  final bool isActive;
  final bool isFastScrolling;
  final ValueChanged<bool>? onScaleStateChanged;

  const SingleImagePreview({
    super.key,
    required this.mediaFile,
    this.thumbnail,
    required this.imageCache,
    required this.settings,
    required this.onSwitchRequest,
    required this.isActive,
    required this.isFastScrolling,
    this.onScaleStateChanged,
  });

  String get filePath => mediaFile.path;
  bool get isRaw => mediaFile.isRaw;

  @override
  State<SingleImagePreview> createState() => _SingleImagePreviewState();
}

class _SingleImagePreviewState extends State<SingleImagePreview> {
  ViewerImage? _thumbnail;
  ViewerImage? _preview;
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
  final Set<int> _activePointers = {};

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
      if (_currentTask != null) {
        _currentTask!.cancel();
        _currentTask = null;
        if (mounted) {
          setState(() {
            _isLoadingPreview = false;
          });
        }
      }
    }

    bool becameActive = widget.isActive && !oldWidget.isActive;
    bool fastScrollStopped =
        widget.isActive && !widget.isFastScrolling && oldWidget.isFastScrolling;
    bool fastScrollStarted =
        widget.isActive && widget.isFastScrolling && !oldWidget.isFastScrolling;

    if (becameActive || fastScrollStopped || fastScrollStarted) {
      // Cancel any ongoing task to restart with correct priority
      _currentTask?.cancel();
      _currentTask = null;
      _isLoadingPreview = false;

      // Reload logic will skip if _thumbnail/_preview are already set
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
    if (_thumbnail == null) {
      // Check if thumbnail is already in cache
      final thumbKey = '${widget.filePath}:thumb';
      final cachedThumb = widget.imageCache.get(thumbKey);

      if (cachedThumb != null) {
        if (mounted) {
          setState(() {
            _thumbnail = cachedThumb;
          });
        }
      } else {
        // If not active, or fast scrolling, use low priority
        final thumbPriority = (!widget.isActive || widget.isFastScrolling)
            ? TaskPriority.low
            : TaskPriority.high;
        ViewerImage? thumb;
        if (widget.isRaw) {
          final task = WorkerService()
              .requestThumbnail(widget.filePath, priority: thumbPriority);
          _currentTask = task;
          final rawThumb = await task.result;
          _currentTask = null;
          if (rawThumb != null) {
            thumb = ViewerImage.fromRaw(rawThumb);
          }
        } else {
          final bytes = await File(widget.filePath).readAsBytes();
          thumb = ViewerImage.fromEncodedBytes(bytes);
        }

        if (mounted && thumb != null) {
          setState(() {
            _thumbnail = thumb;
          });
          // Cache it for fast subsequent switches
          Future(() => widget.imageCache.put(thumbKey, thumb!));
        }
      }
    }

    if (!widget.isActive || widget.isFastScrolling) {
      if (widget.isFastScrolling &&
          _currentTask != null &&
          _thumbnail != null) {
        _currentTask?.cancel();
        _currentTask = null;
        if (mounted) {
          setState(() {
            _isLoadingPreview = false;
          });
        }
      }
      return;
    }

    if (!widget.isRaw || _useEmbeddedPreview) return;
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

    const priority = TaskPriority.high;
    final task = WorkerService().requestPreview(widget.filePath,
        halfSize: _halfSize, priority: priority);
    _currentTask = task;
    final rawPreview = await task.result;
    _currentTask = null;
    final preview = rawPreview == null ? null : ViewerImage.fromRaw(rawPreview);

    if (mounted && widget.isActive) {
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
      final isMetaPressed = keysPressed.contains(LogicalKeyboardKey.metaLeft) ||
          keysPressed.contains(LogicalKeyboardKey.metaRight);
      final isZoomModifierPressed =
          Platform.isMacOS ? (isMetaPressed || isCtrlPressed) : isCtrlPressed;

      if (isZoomModifierPressed) {
        // Zoom centered on mouse pointer
        final double scaleChange = event.scrollDelta.dy < 0 ? 1.1 : 0.9;
        final Offset focalPoint = event.localPosition;

        final Matrix4 matrix = _transformationController.value.clone();

        final Matrix4 scaleMatrix = Matrix4.identity()
          ..translate(focalPoint.dx, focalPoint.dy)
          ..scale(scaleChange)
          ..translate(-focalPoint.dx, -focalPoint.dy);

        final Matrix4 newMatrix = scaleMatrix * matrix;

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
    _activePointers.add(event.pointer);
    _checkPointers();
    // If touch, enable scaling (pinch)
    if (event.kind == PointerDeviceKind.touch) {
      if (!_scaleEnabled) {
        setState(() {
          _scaleEnabled = true;
        });
      }
    } else if (event.kind == PointerDeviceKind.mouse) {
      if (_scaleEnabled) {
        setState(() {
          _scaleEnabled = false;
        });
      }
    }
  }

  void _onPointerUp(PointerUpEvent event) {
    _activePointers.remove(event.pointer);
    _checkPointers();
  }

  void _onPointerCancel(PointerCancelEvent event) {
    _activePointers.remove(event.pointer);
    _checkPointers();
  }

  void _checkPointers() {
    final shouldLock = _activePointers.length >= 2;
    widget.onScaleStateChanged?.call(shouldLock);
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
          onPointerUp: _onPointerUp,
          onPointerCancel: _onPointerCancel,
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
                      image: _thumbnail!,
                      fit: BoxFit.contain,
                      memCacheWidth: 100, // Match grid cache width
                      heroTag: widget.isActive ? widget.filePath : null,
                    ),
                  if (_thumbnail != null)
                    // High-res version (loads on top)
                    RawImageWidget(
                      image: _thumbnail!,
                      fit: BoxFit.contain,
                    ),
                  if (_preview != null && !_useEmbeddedPreview)
                    RawImageWidget(image: _preview!, fit: BoxFit.contain),
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
              widget.isRaw ? (_useEmbeddedPreview ? 'JPG' : 'RAW') : 'IMG',
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
  final ViewerImage image;
  final BoxFit? fit;
  final int? memCacheWidth;
  final String? heroTag;

  const RawImageWidget({
    super.key,
    required this.image,
    this.fit,
    this.memCacheWidth,
    this.heroTag,
  });

  @override
  Widget build(BuildContext context) {
    Widget image = Image.memory(
      this.image.data,
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

class FastPageScrollPhysics extends PageScrollPhysics {
  const FastPageScrollPhysics({super.parent});

  @override
  FastPageScrollPhysics applyTo(ScrollPhysics? ancestor) {
    return FastPageScrollPhysics(parent: buildParent(ancestor));
  }

  @override
  SpringDescription get spring => SpringDescription.withDampingRatio(
        mass: 1.0,
        stiffness: 500.0,
        ratio: 1.0,
      );
}
