import 'dart:async';
import 'dart:isolate';

import 'native_lib.dart';

class WorkerService {
  static final WorkerService _instance = WorkerService._internal();
  factory WorkerService() => _instance;

  // Use a pool of isolates to allow concurrent decoding
  static const int _poolSize = 4;
  final List<SendPort?> _workerSendPorts = List.filled(_poolSize, null);
  final List<Isolate?> _isolates = List.filled(_poolSize, null);
  int _nextWorkerIndex = 0;

  final Map<int, Completer<LibRawImage?>> _pendingRequests = {};
  int _nextRequestId = 0;

  // Deduplication map: key is 'path:type:halfSize' -> requestId
  final Map<String, int> _activeRequestsByKey = {};

  // Track active requests to cancel them if needed (best effort)
  final Set<int> _cancelledRequests = {};

  WorkerService._internal();

  Future<void> init() async {
    if (_isolates[0] != null) return;

    for (int i = 0; i < _poolSize; i++) {
      final receivePort = ReceivePort();
      _isolates[i] = await Isolate.spawn(_workerEntry, receivePort.sendPort);

      // Wait for the worker to send its SendPort
      _workerSendPorts[i] = await receivePort.first as SendPort;

      // Listen for responses
      final responsePort = ReceivePort();
      _workerSendPorts[i]!.send(responsePort.sendPort);

      responsePort.listen(_handleResponse);
    }
  }

  void _handleResponse(dynamic message) {
    if (message is _WorkerResponse) {
      final completer = _pendingRequests.remove(message.requestId);

      // Also remove from deduplication map
      _activeRequestsByKey.removeWhere((key, val) => val == message.requestId);

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

    final dedupeKey = '$path:${type.name}:$halfSize';
    if (_activeRequestsByKey.containsKey(dedupeKey)) {
      final existingReqId = _activeRequestsByKey[dedupeKey]!;
      // Bump the priority of the existing request
      bumpRequest(existingReqId, priority);

      if (_pendingRequests.containsKey(existingReqId)) {
        final result = await _pendingRequests[existingReqId]!.future;
        return result as T;
      }
    }

    _activeRequestsByKey[dedupeKey] = requestId;
    final completer = Completer<LibRawImage?>();
    _pendingRequests[requestId] = completer;

    final workerIndex = _nextWorkerIndex;
    _nextWorkerIndex = (_nextWorkerIndex + 1) % _poolSize;

    _workerSendPorts[workerIndex]!.send(_WorkerRequest(
      requestId: requestId,
      path: path,
      type: type,
      halfSize: halfSize,
      priority: priority,
    ));

    final result = await completer.future;
    return result as T;
  }

  void bumpRequest(int requestId, TaskPriority priority) {
    for (int i = 0; i < _poolSize; i++) {
      if (_workerSendPorts[i] != null) {
        _workerSendPorts[i]!.send(_BumpRequest(requestId, priority));
      }
    }
  }

  void cancelRequest(int requestId) {
    _cancelledRequests.add(requestId);
    for (int i = 0; i < _poolSize; i++) {
      if (_workerSendPorts[i] != null) {
        _workerSendPorts[i]!.send(_CancelRequest(requestId));
      }
    }
    // Remove from pending requests map and complete with null to avoid hanging
    final completer = _pendingRequests.remove(requestId);
    _activeRequestsByKey.removeWhere((key, val) => val == requestId);
    if (completer != null && !completer.isCompleted) {
      completer.complete(null);
    }
  }

  void dispose() {
    for (int i = 0; i < _poolSize; i++) {
      _isolates[i]?.kill();
      _isolates[i] = null;
      _workerSendPorts[i] = null;
    }
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

class _BumpRequest {
  final int requestId;
  final TaskPriority priority;
  _BumpRequest(this.requestId, this.priority);
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
    } else if (message is _BumpRequest) {
      _WorkerRequest? foundRequest;

      // Find and remove the request from whichever queue it's in
      int index = highPriorityRequests
          .indexWhere((r) => r.requestId == message.requestId);
      if (index != -1) {
        foundRequest = highPriorityRequests.removeAt(index);
      } else {
        index = lowPriorityRequests
            .indexWhere((r) => r.requestId == message.requestId);
        if (index != -1) {
          foundRequest = lowPriorityRequests.removeAt(index);
        }
      }

      // If found, re-add it to the end (top of stack) of the target priority queue
      if (foundRequest != null) {
        if (message.priority == TaskPriority.high) {
          highPriorityRequests.add(foundRequest);
        } else {
          lowPriorityRequests.add(foundRequest);
        }
        if (!isProcessing) {
          processQueue();
        }
      }
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
