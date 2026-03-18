// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// ignore_for_file: annotate_overrides, implementation_imports

import 'dart:async';
import 'dart:js_interop';

import 'package:isolate_manager/src/base/contactor/isolate_contactor_controller/web_platform/isolate_contactor_controller_web_worker.dart';
import 'package:isolate_manager/src/isolate_manager_controller/web.dart';
import 'package:rpc_dart/rpc_dart.dart';
import 'package:web/web.dart';

typedef RpcIsolateEntrypoint = void Function(
    IRpcTransport transport, Map<String, dynamic> customParams);

const bool _kIsWasm = bool.fromEnvironment('dart.tool.dart2wasm');

const String _defaultWorkerName = 'rpcIsolateWorker';
const String _logPrefixHost = '[rpc_isolate_transport][host]';
const String _logPrefixWorker = '[rpc_isolate_transport][worker]';

@JS('self')
external DedicatedWorkerGlobalScope get _workerSelf;

/// Web implementation backed by isolate_manager Worker controllers.
abstract interface class RpcIsolateTransport {
  static Future<({IRpcTransport transport, void Function() kill})> spawn({
    required RpcIsolateEntrypoint entrypoint,
    Map<String, dynamic>? customParams,
    String isolateId = 'default',
    String? debugName,
    RpcSecurityPolicy policy = const RpcSecurityPolicy(),
    Uri? workerUri,
  }) async {
    // On web we cannot transfer the entrypoint function; user must expose it in a
    // worker. Keeping the parameter for API parity.
    final _ = entrypoint;

    final uri = _resolveWorkerUri(workerUri);
    final workerOptions = _buildWorkerOptions(debugName);
    final worker = workerOptions == null
        ? Worker(uri.toString().toJS)
        : Worker(uri.toString().toJS, workerOptions);

    final controller = IsolateContactorControllerImplWorker<Object?, Object?>(
      worker,
      workerConverter: (value) => (value as Map).cast<String, Object?>(),
      onDispose: null,
      debugMode: false,
    );

    final hostTransport = _WebHostTransport(
      controller: controller,
      policy: policy,
    );

    // Wait for worker init acknowledgment to reduce early message loss.
    await controller.ensureInitialized.future
        .timeout(const Duration(seconds: 5), onTimeout: () {});

    // Deliver initial parameters to the worker.
    controller.sendIsolate(
      _BridgeMessage(
        type: _BridgeType.init,
        streamId: 0,
        payload: customParams ?? const <String, Object?>{},
      ).toMap(),
    );

    void kill() {
      hostTransport.markRemoteExit();
      unawaited(hostTransport.close());
      worker.terminate();
    }

    return (transport: hostTransport, kill: kill);
  }
}

/// Helper to be called from inside the worker entrypoint. Users annotate their
/// worker with @isolateManagerCustomWorker and invoke this to wire RPC.
void runRpcIsolateManagerWorker(
  RpcIsolateEntrypoint entrypoint, {
  RpcSecurityPolicy policy = const RpcSecurityPolicy(),
}) {
  final scope = _workerSelf;

  final controller = IsolateManagerControllerImpl<Object?, Object?>(scope,
      onDispose: () => scope.close());

  final transport = _WebWorkerTransport(
    controller: controller,
    policy: policy,
    onShutdown: () => scope.close(),
  );

  // Signal ready state.
  controller.initialized();

  controller.onIsolateMessage.first.then((raw) {
    try {
      final msg = _BridgeMessage.fromMap(raw);
      if (msg != null && msg.type == _BridgeType.init && msg.payload is Map) {
        final params = (msg.payload as Map).cast<String, dynamic>();
        entrypoint(transport, Map<String, dynamic>.from(params));
        return;
      }
    } catch (error, stackTrace) {
      _logWorkerError(
        'Malformed init payload from host: $raw\n$error\n$stackTrace',
      );
      // Ignore malformed init; fall back to empty params.
    }
    try {
      entrypoint(transport, const <String, dynamic>{});
    } catch (error, stackTrace) {
      _logWorkerError('Entrypoint threw: $error\n$stackTrace');
      unawaited(transport.close());
      Zone.current.handleUncaughtError(error, stackTrace);
    }
  });
}

enum _BridgeType { init, metadata, data, finish, close }

class _BridgeMessage {
  final _BridgeType type;
  final int streamId;
  final bool endStream;
  final Map<String, Object?>? metadata;
  final Object? payload;
  final String? methodPath;

  const _BridgeMessage({
    required this.type,
    required this.streamId,
    this.endStream = false,
    this.metadata,
    this.payload,
    this.methodPath,
  });

  Map<String, Object?> toMap() => {
        'type': switch (type) {
          _BridgeType.init => 'init',
          _BridgeType.metadata => 'metadata',
          _BridgeType.data => 'data',
          _BridgeType.finish => 'finish',
          _BridgeType.close => 'close',
        },
        'streamId': streamId,
        if (endStream) 'endStream': true,
        if (metadata != null) 'metadata': metadata,
        if (payload != null) 'payload': payload,
        if (methodPath != null) 'methodPath': methodPath,
      };

  static _BridgeMessage? fromMap(dynamic raw) {
    if (raw is! Map) return null;
    final typeRaw = raw['type'];
    final streamId = _asInt(raw['streamId']);
    if (typeRaw is! String || streamId == null) return null;
    final type = switch (typeRaw) {
      'init' => _BridgeType.init,
      'metadata' => _BridgeType.metadata,
      'data' => _BridgeType.data,
      'finish' => _BridgeType.finish,
      'close' => _BridgeType.close,
      _ => null,
    };
    if (type == null) return null;
    final metadata = raw['metadata'];
    return _BridgeMessage(
      type: type,
      streamId: streamId,
      endStream: raw['endStream'] == true,
      metadata: metadata is Map ? metadata.cast<String, Object?>() : null,
      payload: raw['payload'],
      methodPath: raw['methodPath'] as String?,
    );
  }
}

RpcMetadata _decodeMetadata(Map<String, Object?> raw) {
  final headersRaw = raw['headers'];
  if (headersRaw is! List) {
    throw StateError('Invalid metadata headers: $raw');
  }
  final headers = headersRaw
      .whereType<Map>()
      .map(
        (header) => RpcHeader(
          header['name']?.toString() ?? '',
          header['value']?.toString() ?? '',
        ),
      )
      .toList();
  return RpcMetadata(headers);
}

Map<String, Object?> _encodeMetadata(RpcMetadata metadata) => {
      'headers': metadata.headers
          .map((header) => {
                'name': header.name,
                'value': header.value,
              })
          .toList(),
    };

int? _asInt(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  return null;
}

Uint8List _materializeBytes(Object? raw) {
  if (raw is Uint8List) return raw;
  if (raw is ByteBuffer) return Uint8List.view(raw);
  if (raw is List) {
    return Uint8List.fromList(
      raw.map((value) => (value as num).toInt()).toList(growable: false),
    );
  }
  throw StateError('Unsupported binary payload: $raw');
}

List<int> _serializeBytes(Uint8List data) => data.toList(growable: false);

void _logError(String message) {
  print('$_logPrefixHost: $message');
}

void _logWorkerError(String message) {
  print('$_logPrefixWorker: $message');
}

WorkerOptions? _buildWorkerOptions(String? debugName) {
  if (!_kIsWasm && debugName == null) return null;
  if (_kIsWasm && debugName != null) {
    return WorkerOptions(type: 'module', name: debugName);
  }
  if (_kIsWasm) {
    return WorkerOptions(type: 'module');
  }
  return WorkerOptions(name: debugName!);
}

Uri _resolveWorkerUri(Uri? provided) {
  if (provided != null) return provided;
  final defaultPath = Uri.parse('$_defaultWorkerName.js');
  if (defaultPath.isAbsolute) return defaultPath;
  return Uri.base.resolveUri(defaultPath);
}

class _WebHostTransport implements IRpcTransport {
  @override
  bool get isClient => true;

  final IsolateContactorControllerImplWorker<Object?, Object?> _controller;
  final StreamController<RpcTransportMessage> _messages =
      StreamController<RpcTransportMessage>.broadcast();
  final Map<int, bool> _streamFinished = <int, bool>{};
  final RpcSecurityPolicy _policy;

  int _nextStreamId = 1;
  bool _isClosed = false;
  bool _remoteExited = false;
  Object? _remoteError;

  _WebHostTransport({
    required IsolateContactorControllerImplWorker<Object?, Object?> controller,
    required RpcSecurityPolicy policy,
  })  : _controller = controller,
        _policy = policy {
    _controller.onMessage.listen((raw) {
      final message = _BridgeMessage.fromMap(raw);
      if (message == null) {
        _logError('Dropped malformed message from worker: $raw');
        return;
      }
      try {
        _handleMessage(message);
      } catch (error, stackTrace) {
        _logError('Failed to handle incoming message: $error\n$stackTrace');
        _remoteError = error;
        unawaited(_closeInternal(notifyRemote: false));
        Zone.current.handleUncaughtError(error, stackTrace);
      }
    }, onError: (error, stack) {
      _logError('Controller onMessage error: $error\n$stack');
      _remoteError = error;
      unawaited(_closeInternal(notifyRemote: false));
    });
  }

  void markRemoteExit() {
    _remoteExited = true;
  }

  Future<void> _closeInternal({required bool notifyRemote}) async {
    if (_isClosed) return;
    _isClosed = true;
    _streamFinished.clear();

    if (notifyRemote) {
      _controller.sendIsolate(
        _BridgeMessage(type: _BridgeType.close, streamId: 0).toMap(),
      );
    }

    await _controller.close();

    if (!_messages.isClosed) {
      await _messages.close();
    }
  }

  void _handleMessage(_BridgeMessage message) {
    if (_isClosed) return;
    try {
      switch (message.type) {
        case _BridgeType.init:
          break;
        case _BridgeType.metadata:
          final metadata =
              _decodeMetadata(message.metadata ?? const <String, Object?>{});
          _messages.add(
            RpcTransportMessage(
              metadata: metadata,
              isEndOfStream: message.endStream,
              streamId: message.streamId,
              methodPath: message.methodPath,
            ),
          );
          break;
        case _BridgeType.data:
          final data = _materializeBytes(message.payload);
          _messages.add(
            RpcTransportMessage(
              payload: data,
              isEndOfStream: message.endStream,
              streamId: message.streamId,
              methodPath: message.methodPath,
            ),
          );
          break;
        case _BridgeType.finish:
          _messages.add(
            RpcTransportMessage(
              isEndOfStream: true,
              streamId: message.streamId,
            ),
          );
          break;
        case _BridgeType.close:
          _remoteExited = true;
          unawaited(_closeInternal(notifyRemote: false));
          break;
      }
    } catch (error, stackTrace) {
      if (_policy.closeOnProtocolError) {
        _logError('Protocol error while handling message: $message\n$error');
        unawaited(close());
      } else {
        Zone.current.handleUncaughtError(error, stackTrace);
      }
    }
  }

  @override
  Stream<RpcTransportMessage> get incomingMessages => _messages.stream;

  @override
  Stream<RpcTransportMessage> getMessagesForStream(int streamId) =>
      incomingMessages.where((m) => m.streamId == streamId);

  Map<String, Object?> _healthDetails() => {
        'isClosed': _isClosed,
        'activeStreams': _streamFinished.length,
        'remoteExited': _remoteExited,
        'remoteError': _remoteError?.toString(),
      };

  @override
  Future<RpcHealthStatus> health() async {
    final details = _healthDetails();
    if (_remoteError != null) {
      return RpcHealthStatus.unhealthy(
        component: runtimeType.toString(),
        message: 'Worker crashed',
        details: details,
      );
    }
    if (_remoteExited) {
      return RpcHealthStatus.closed(
        component: runtimeType.toString(),
        message: 'Worker exited',
        details: details,
      );
    }
    if (_messages.isClosed || _isClosed) {
      return RpcHealthStatus.closed(
        component: runtimeType.toString(),
        message: 'Worker transport closed',
        details: details,
      );
    }
    return RpcHealthStatus.healthy(
      component: runtimeType.toString(),
      message: 'Worker transport ready',
      details: details,
    );
  }

  @override
  Future<RpcHealthStatus> reconnect() async {
    return RpcHealthStatus.degraded(
      component: runtimeType.toString(),
      message: 'Web worker transport cannot reconnect; restart the worker',
      details: {..._healthDetails(), 'supported': false},
    );
  }

  @override
  int createStream() {
    if (_streamFinished.length >= _policy.maxActiveStreams) {
      throw StateError(
        'Too many active streams: ${_streamFinished.length} (max: ${_policy.maxActiveStreams})',
      );
    }
    final streamId = _nextStreamId;
    _nextStreamId += 2;
    _streamFinished[streamId] = false;
    return streamId;
  }

  void _send(_BridgeMessage message) {
    try {
      _controller.sendIsolate(message.toMap());
    } catch (error, stackTrace) {
      _logError('Failed to send to worker: $error\n$stackTrace');
      unawaited(_closeInternal(notifyRemote: false));
      Error.throwWithStackTrace(error, stackTrace);
    }
  }

  @override
  Future<void> sendMetadata(
    int streamId,
    RpcMetadata metadata, {
    bool endStream = false,
  }) async {
    if (_isClosed) return;
    _policy.validateMetadata(metadata);
    _send(
      _BridgeMessage(
        type: _BridgeType.metadata,
        streamId: streamId,
        endStream: endStream,
        metadata: _encodeMetadata(metadata),
        methodPath: metadata.methodPath,
      ),
    );
    if (endStream) {
      _streamFinished[streamId] = true;
    }
  }

  @override
  Future<void> sendMessage(
    int streamId,
    Uint8List data, {
    bool endStream = false,
  }) async {
    if (_isClosed) return;
    _send(
      _BridgeMessage(
        type: _BridgeType.data,
        streamId: streamId,
        endStream: endStream,
        payload: _serializeBytes(data),
      ),
    );
    if (endStream) {
      _streamFinished[streamId] = true;
    }
  }

  @override
  Future<void> finishSending(int streamId) async {
    if (_isClosed) return;
    if (_streamFinished[streamId] == true) return;
    _streamFinished[streamId] = true;
    _send(_BridgeMessage(type: _BridgeType.finish, streamId: streamId));
  }

  @override
  bool releaseStreamId(int streamId) {
    if (_isClosed) return false;
    return _streamFinished.remove(streamId) != null;
  }

  @override
  Future<void> close() async {
    await _closeInternal(notifyRemote: true);
  }

  @override
  bool get isClosed => _isClosed;

  @override
  bool get supportsZeroCopy => false;

  @override
  Future<void> sendDirectObject(
    int streamId,
    Object object, {
    bool endStream = false,
  }) async {
    throw UnsupportedError(
      'sendDirectObject is not supported for web worker transports. '
      'Use sendMessage() with serialization.',
    );
  }
}

class _WebWorkerTransport implements IRpcTransport {
  @override
  bool get isClient => false;

  final IsolateManagerControllerImpl<Object?, Object?> _controller;
  final StreamController<RpcTransportMessage> _messages =
      StreamController<RpcTransportMessage>.broadcast();
  final Map<int, bool> _streamFinished = <int, bool>{};
  final RpcSecurityPolicy _policy;
  final void Function() _onShutdown;

  int _nextStreamId = 2;
  bool _isClosed = false;

  _WebWorkerTransport({
    required IsolateManagerControllerImpl<Object?, Object?> controller,
    required RpcSecurityPolicy policy,
    required void Function() onShutdown,
  })  : _controller = controller,
        _policy = policy,
        _onShutdown = onShutdown {
    _controller.onIsolateMessage.listen((raw) {
      final msg = _BridgeMessage.fromMap(raw);
      if (msg == null) {
        _logWorkerError('Dropped malformed message from host: $raw');
        return;
      }
      _handleMessage(msg);
    }, onError: (_) {
      unawaited(_closeInternal(notifyRemote: false));
    });
  }

  Future<void> _closeInternal({required bool notifyRemote}) async {
    if (_isClosed) return;
    _isClosed = true;
    _streamFinished.clear();

    if (notifyRemote) {
      _controller.sendResult(
        _BridgeMessage(type: _BridgeType.close, streamId: 0).toMap(),
      );
    }

    await _controller.close();
    _onShutdown();

    if (!_messages.isClosed) {
      await _messages.close();
    }
  }

  void _handleMessage(_BridgeMessage message) {
    if (_isClosed) return;
    if (message.streamId < 0) return;
    try {
      switch (message.type) {
        case _BridgeType.init:
          break;
        case _BridgeType.metadata:
          final metadata =
              _decodeMetadata(message.metadata ?? const <String, Object?>{});
          _messages.add(
            RpcTransportMessage(
              metadata: metadata,
              isEndOfStream: message.endStream,
              streamId: message.streamId,
              methodPath: message.methodPath,
            ),
          );
          break;
        case _BridgeType.data:
          final data = _materializeBytes(message.payload);
          _messages.add(
            RpcTransportMessage(
              payload: data,
              isEndOfStream: message.endStream,
              streamId: message.streamId,
              methodPath: message.methodPath,
            ),
          );
          break;
        case _BridgeType.finish:
          _messages.add(
            RpcTransportMessage(
              isEndOfStream: true,
              streamId: message.streamId,
            ),
          );
          break;
        case _BridgeType.close:
          unawaited(_closeInternal(notifyRemote: false));
          break;
      }
    } catch (error, stackTrace) {
      if (_policy.closeOnProtocolError) {
        _logWorkerError(
          'Protocol error in worker while handling message: $message\n$error',
        );
        unawaited(close());
      } else {
        Zone.current.handleUncaughtError(error, stackTrace);
      }
    }
  }

  @override
  Stream<RpcTransportMessage> get incomingMessages => _messages.stream;

  @override
  Stream<RpcTransportMessage> getMessagesForStream(int streamId) =>
      incomingMessages.where((m) => m.streamId == streamId);

  Map<String, Object?> _healthDetails() => {
        'isClosed': _isClosed,
        'activeStreams': _streamFinished.length,
      };

  @override
  Future<RpcHealthStatus> health() async {
    final details = _healthDetails();
    if (_messages.isClosed || _isClosed) {
      return RpcHealthStatus.closed(
        component: runtimeType.toString(),
        message: 'Worker transport closed',
        details: details,
      );
    }
    return RpcHealthStatus.healthy(
      component: runtimeType.toString(),
      message: 'Worker transport ready',
      details: details,
    );
  }

  @override
  Future<RpcHealthStatus> reconnect() async {
    return RpcHealthStatus.degraded(
      component: runtimeType.toString(),
      message: 'Web worker transport cannot reconnect; restart the worker',
      details: {..._healthDetails(), 'supported': false},
    );
  }

  @override
  int createStream() {
    if (_streamFinished.length >= _policy.maxActiveStreams) {
      throw StateError(
        'Too many active streams: ${_streamFinished.length} (max: ${_policy.maxActiveStreams})',
      );
    }
    final streamId = _nextStreamId;
    _nextStreamId += 2;
    _streamFinished[streamId] = false;
    return streamId;
  }

  void _send(_BridgeMessage message) {
    try {
      _controller.sendResult(message.toMap());
    } catch (error, stackTrace) {
      _logWorkerError('Failed to send to host: $error\n$stackTrace');
      unawaited(_closeInternal(notifyRemote: false));
      Error.throwWithStackTrace(error, stackTrace);
    }
  }

  @override
  Future<void> sendMetadata(
    int streamId,
    RpcMetadata metadata, {
    bool endStream = false,
  }) async {
    if (_isClosed) return;
    _policy.validateMetadata(metadata);
    _send(
      _BridgeMessage(
        type: _BridgeType.metadata,
        streamId: streamId,
        endStream: endStream,
        metadata: _encodeMetadata(metadata),
        methodPath: metadata.methodPath,
      ),
    );
    if (endStream) {
      _streamFinished[streamId] = true;
    }
  }

  @override
  Future<void> sendMessage(
    int streamId,
    Uint8List data, {
    bool endStream = false,
  }) async {
    if (_isClosed) return;
    _send(
      _BridgeMessage(
        type: _BridgeType.data,
        streamId: streamId,
        endStream: endStream,
        payload: _serializeBytes(data),
      ),
    );
    if (endStream) {
      _streamFinished[streamId] = true;
    }
  }

  @override
  Future<void> finishSending(int streamId) async {
    if (_isClosed) return;
    if (_streamFinished[streamId] == true) return;
    _streamFinished[streamId] = true;
    _send(_BridgeMessage(type: _BridgeType.finish, streamId: streamId));
  }

  @override
  bool releaseStreamId(int streamId) {
    if (_isClosed) return false;
    return _streamFinished.remove(streamId) != null;
  }

  @override
  Future<void> close() async {
    await _closeInternal(notifyRemote: true);
  }

  @override
  bool get isClosed => _isClosed;

  @override
  bool get supportsZeroCopy => false;

  @override
  Future<void> sendDirectObject(
    int streamId,
    Object object, {
    bool endStream = false,
  }) async {
    throw UnsupportedError(
      'sendDirectObject is not supported for web worker transports. '
      'Use sendMessage() with serialization.',
    );
  }
}
