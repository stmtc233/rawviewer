import 'dart:async';
import 'dart:isolate';

import 'native_lib.dart';

class WorkerService {
  static final WorkerService _instance = WorkerService._internal();
  factory WorkerService() => _instance;

  SendPort? _workerSendPort;
  final Map<int, Completer<LibRawImage?>> _pendingRequests = {};
  int _nextRequestId = 0;
  Isolate? _isolate;

  // Track active requests to cancel them if needed (best effort)
  final Set<int> _cancelledRequests = {};

  WorkerService._internal();

  Future<void> init() async {
    if (_isolate != null) return;

    final receivePort = ReceivePort();
    _isolate = await Isolate.spawn(_workerEntry, receivePort.sendPort);

    // Wait for the worker to send its SendPort
    _workerSendPort = await receivePort.first as SendPort;

    // Listen for responses
    final responsePort = ReceivePort();
    _workerSendPort!.send(responsePort.sendPort);

    responsePort.listen(_handleResponse);
  }

  void _handleResponse(dynamic message) {
    if (message is _WorkerResponse) {
      final completer = _pendingRequests.remove(message.requestId);
      if (completer != null) {
        if (_cancelledRequests.contains(message.requestId)) {
          _cancelledRequests.remove(message.requestId);
          // Just ignore the result if cancelled
          return;
        }

        if (message.error != null) {
          completer.completeError(message.error!);
        } else {
          completer.complete(message.image);
        }
      }
    }
  }

  WorkerTask<LibRawImage?> requestThumbnail(String path,
      {TaskPriority priority = TaskPriority.high}) {
    final requestId = _nextRequestId++;
    return WorkerTask(this, requestId, path, _RequestType.thumbnail,
        priority: priority);
  }

  WorkerTask<LibRawImage?> requestPreview(String path,
      {int halfSize = 1, TaskPriority priority = TaskPriority.high}) {
    final requestId = _nextRequestId++;
    return WorkerTask(this, requestId, path, _RequestType.preview,
        halfSize: halfSize, priority: priority);
  }

  Future<T> _executeTask<T>(int requestId, String path, _RequestType type,
      {int halfSize = 1, TaskPriority priority = TaskPriority.high}) async {
    await init();
    final completer = Completer<LibRawImage?>();
    _pendingRequests[requestId] = completer;

    _workerSendPort!.send(_WorkerRequest(
      requestId: requestId,
      path: path,
      type: type,
      halfSize: halfSize,
      priority: priority,
    ));

    final result = await completer.future;
    return result as T;
  }

  void cancelRequest(int requestId) {
    _cancelledRequests.add(requestId);
    if (_workerSendPort != null) {
      _workerSendPort!.send(_CancelRequest(requestId));
    }
    // Remove from pending requests map and complete with null to avoid hanging
    final completer = _pendingRequests.remove(requestId);
    if (completer != null && !completer.isCompleted) {
      completer.complete(null);
    }
  }

  void dispose() {
    _isolate?.kill();
    _isolate = null;
    _workerSendPort = null;
    _pendingRequests.clear();
    _cancelledRequests.clear();
  }
}

enum TaskPriority { high, low }

class WorkerTask<T> {
  final WorkerService _service;
  final int requestId;
  final String path;
  final _RequestType type;
  final int halfSize;
  final TaskPriority priority;

  WorkerTask(this._service, this.requestId, this.path, this.type,
      {this.halfSize = 1, this.priority = TaskPriority.high});

  Future<T> get result => _service._executeTask<T>(requestId, path, type,
      halfSize: halfSize, priority: priority);

  void cancel() {
    _service.cancelRequest(requestId);
  }
}

enum _RequestType { thumbnail, preview }

class _WorkerRequest {
  final int requestId;
  final String path;
  final _RequestType type;
  final int halfSize;
  final TaskPriority priority;

  _WorkerRequest({
    required this.requestId,
    required this.path,
    required this.type,
    this.halfSize = 1,
    this.priority = TaskPriority.high,
  });
}

class _CancelRequest {
  final int requestId;
  _CancelRequest(this.requestId);
}

class _WorkerResponse {
  final int requestId;
  final LibRawImage? image;
  final String? error;

  _WorkerResponse({
    required this.requestId,
    this.image,
    this.error,
  });
}

void _workerEntry(SendPort mainSendPort) {
  final receivePort = ReceivePort();
  mainSendPort.send(receivePort.sendPort);

  SendPort? replyPort;
  final Set<int> cancelledIds = {};
  // Use two lists for priority handling
  final List<_WorkerRequest> highPriorityRequests = [];
  final List<_WorkerRequest> lowPriorityRequests = [];
  bool isProcessing = false;

  // Process the queue
  Future<void> processQueue() async {
    if (isProcessing) return;
    isProcessing = true;

    while (highPriorityRequests.isNotEmpty || lowPriorityRequests.isNotEmpty) {
      // Prioritize high priority requests, then low priority
      // Use LIFO for both queues (take the last request)
      _WorkerRequest request;
      if (highPriorityRequests.isNotEmpty) {
        request = highPriorityRequests.removeLast();
      } else {
        request = lowPriorityRequests.removeLast();
      }

      if (cancelledIds.contains(request.requestId)) {
        cancelledIds.remove(request.requestId);
        continue;
      }

      if (replyPort == null) {
        // Should not happen if protocol is followed
        continue;
      }

      try {
        LibRawImage? result;
        if (request.type == _RequestType.thumbnail) {
          result = getThumbnailSync(request.path);
        } else {
          result =
              getPreviewSync(PreviewRequest(request.path, request.halfSize));
        }

        // Check cancellation again after processing
        if (cancelledIds.contains(request.requestId)) {
          cancelledIds.remove(request.requestId);
          continue;
        }

        replyPort!.send(_WorkerResponse(
          requestId: request.requestId,
          image: result,
        ));
      } catch (e) {
        if (cancelledIds.contains(request.requestId)) {
          cancelledIds.remove(request.requestId);
          continue;
        }
        replyPort!.send(_WorkerResponse(
          requestId: request.requestId,
          error: e.toString(),
        ));
      }

      // Yield to event loop to allow incoming messages (like Cancel or new Requests)
      await Future.delayed(Duration.zero);
    }
    isProcessing = false;
  }

  receivePort.listen((message) {
    if (message is SendPort) {
      replyPort = message;
    } else if (message is _CancelRequest) {
      cancelledIds.add(message.requestId);
      // Optimization: Remove from pending queues immediately if present
      highPriorityRequests.removeWhere((r) => r.requestId == message.requestId);
      lowPriorityRequests.removeWhere((r) => r.requestId == message.requestId);
    } else if (message is _WorkerRequest) {
      if (message.priority == TaskPriority.high) {
        highPriorityRequests.add(message);
      } else {
        lowPriorityRequests.add(message);
      }
      if (!isProcessing) {
        processQueue();
      }
    }
  });
}
