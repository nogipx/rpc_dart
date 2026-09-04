// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// ignore_for_file: implementation_imports

import 'dart:async';
import 'dart:js_interop';

import 'package:isolate_manager/src/base/contactor/isolate_contactor_controller/web_platform/isolate_contactor_controller_web_worker.dart';
import 'package:isolate_manager/src/isolate_manager_controller/web.dart';
import 'package:rpc_dart/rpc_dart.dart';
import 'package:web/web.dart';

typedef RpcIsolateEntrypoint =
    void Function(IRpcTransport transport, Map<String, dynamic> customParams);

const bool _kIsWasm = bool.fromEnvironment('dart.tool.dart2wasm');
const String _defaultWorkerName = 'rpcIsolateWorker';

/// How long to wait for the worker's post-entrypoint `ready` ack before
/// assuming it is a worker built before that ack existed and proceeding anyway.
///
/// Deliberately NOT `startupTimeout`: this bound is a compatibility fallback
/// whose expiry is a SUCCESS path, whereas `startupTimeout` bounds failures.
/// Tying them together would mean a generous startup budget also made every
/// legacy worker wait that long before its first call.
const Duration _readyGracePeriod = Duration(seconds: 5);

@JS('self')
external DedicatedWorkerGlobalScope get _workerSelf;

// -- Bridge message format (Map-based, for structured-clone transfer) ---------

enum _BridgeType { init, ready, metadata, data, finish, close }

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
      _BridgeType.ready => 'ready',
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
      'ready' => _BridgeType.ready,
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

// -- Web multiplexed channel --------------------------------------------------

/// [IRpcMultiplexedChannel] backed by isolate_manager controller (web workers).
///
/// Does NOT support zero-copy -- bytes are serialized via structured clone.
class _WebMultiplexedChannel implements IRpcMultiplexedChannel {
  final void Function(Map<String, Object?> data) _send;
  final StreamController<RpcTransportMessage> _incomingCtl =
      StreamController<RpcTransportMessage>.broadcast(sync: true);
  late final StreamSubscription _messageSub;
  bool _closed = false;
  final void Function()? _onClose;

  _WebMultiplexedChannel({
    required Stream<dynamic> messageStream,
    required void Function(Map<String, Object?> data) send,
    void Function()? onClose,
  }) : _send = send,
       _onClose = onClose {
    _messageSub = messageStream.listen(
      (raw) {
        final msg = _BridgeMessage.fromMap(raw);
        if (msg != null) _handleMessage(msg);
      },
      onError: (_) {
        if (!_closed) close();
      },
      onDone: () {
        if (!_closed) close();
      },
    );
  }

  @override
  bool get isClosed => _closed;

  @override
  bool get supportsZeroCopy => false;

  @override
  Stream<RpcTransportMessage> get incoming => _incomingCtl.stream;

  @override
  Future<void> send(RpcTransportMessage message) async {
    if (_closed) return;

    _BridgeType type;
    Map<String, Object?>? metadata;
    Object? payload;

    if (message.payload != null) {
      type = _BridgeType.data;
      payload = _serializeBytes(message.payload!);
    } else if (message.metadata != null) {
      type = _BridgeType.metadata;
      metadata = _encodeMetadata(message.metadata!);
    } else if (message.isEndOfStream) {
      type = _BridgeType.finish;
    } else {
      return;
    }

    try {
      _send(
        _BridgeMessage(
          type: type,
          streamId: message.streamId,
          endStream: message.isEndOfStream,
          metadata: metadata,
          payload: payload,
          methodPath: message.methodPath,
        ).toMap(),
      );
    } catch (_) {
      await close();
    }
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;

    try {
      _send(_BridgeMessage(type: _BridgeType.close, streamId: 0).toMap());
    } catch (_) {}

    await _messageSub.cancel();
    if (!_incomingCtl.isClosed) await _incomingCtl.close();
    _onClose?.call();
  }

  void _handleMessage(_BridgeMessage message) {
    if (_closed || _incomingCtl.isClosed) return;
    if (message.streamId < 0) return;

    switch (message.type) {
      case _BridgeType.init:
      case _BridgeType.ready:
        break;
      case _BridgeType.metadata:
        _incomingCtl.add(
          RpcTransportMessage(
            metadata: _decodeMetadata(
              message.metadata ?? const <String, Object?>{},
            ),
            isEndOfStream: message.endStream,
            streamId: message.streamId,
            methodPath: message.methodPath,
          ),
        );
      case _BridgeType.data:
        _incomingCtl.add(
          RpcTransportMessage(
            payload: _materializeBytes(message.payload),
            isEndOfStream: message.endStream,
            streamId: message.streamId,
            methodPath: message.methodPath,
          ),
        );
      case _BridgeType.finish:
        _incomingCtl.add(
          RpcTransportMessage(isEndOfStream: true, streamId: message.streamId),
        );
      case _BridgeType.close:
        close();
    }
  }
}

// -- Public API ---------------------------------------------------------------

/// Web implementation backed by isolate_manager Worker controllers.
abstract interface class RpcIsolateTransport {
  static Future<({IRpcTransport transport, void Function() kill})> spawn({
    required RpcIsolateEntrypoint entrypoint,
    Map<String, dynamic>? customParams,
    String isolateId = 'default',
    String? debugName,
    RpcSecurityPolicy policy = const RpcSecurityPolicy(),
    Uri? workerUri,
    Duration startupTimeout = const Duration(seconds: 30),
  }) async {
    // On web we cannot transfer the entrypoint function; user must expose it
    // in a worker. Keeping the parameter for API parity.
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

    final channel = _WebMultiplexedChannel(
      messageStream: controller.onMessage,
      send: controller.sendIsolate,
      onClose: () => controller.close(),
    );
    final transport = RpcChannelTransport(
      channel: channel,
      isClient: true,
      policy: policy,
    );

    // A worker that fails to LOAD -- a 404 on the script, or a parse error --
    // fires an `error` event on the Worker object and then does nothing else.
    // Nothing used to listen, so the two waits below simply expired and spawn()
    // handed back a transport wired to a worker that does not exist. Measured
    // in Chrome against a URI that 404s:
    //
    //   spawn() threw : NO -- returned a transport
    //   spawn() took  : 10002ms   (the two swallowed 5s waits)
    //   isClosed      : false
    //   health        : healthy / Transport ready
    //   a call on it  : HUNG, forever
    //
    // The VM sibling wires onError/onExit for exactly this reason, and its own
    // comment says so: a worker that crashes during startup must make spawn()
    // throw "instead of returning a silently-dead transport". This is that.
    final workerFailed = Completer<Object>();
    void reportWorkerError(String what) {
      if (!workerFailed.isCompleted) workerFailed.complete(what);
    }

    final errorListener = (Event event) {
      // `event is ErrorEvent` is meaningless across JS interop (it is always
      // true and checks nothing), so ask the JS type system with isA. The
      // message is empty for a cross-origin or 404 load failure anyway -- the
      // event firing at all is the signal.
      final reported = event.isA<ErrorEvent>()
          ? (event as ErrorEvent).message
          : '';
      reportWorkerError(
        reported.isNotEmpty
            ? reported
            : 'the worker script failed to load or threw during startup',
      );
    }.toJS;
    worker.addEventListener('error', errorListener);
    worker.addEventListener('messageerror', errorListener);

    /// Races [future] against a worker error and the startup budget.
    Future<void> awaitStartup(Future<void> future, String phase) async {
      await Future.any([
        future,
        workerFailed.future.then(
          (reason) => throw StateError(
            'RpcIsolateTransport.spawn: worker "$uri" failed during $phase: '
            '$reason',
          ),
        ),
      ]).timeout(
        startupTimeout,
        onTimeout: () => throw TimeoutException(
          'RpcIsolateTransport.spawn: worker "$uri" did not complete $phase '
          'within $startupTimeout.',
          startupTimeout,
        ),
      );
    }

    /// Releases everything spawn() built, so a failed startup leaves nothing
    /// behind -- the worker itself included.
    Future<void> abandon() async {
      worker.removeEventListener('error', errorListener);
      worker.removeEventListener('messageerror', errorListener);
      await transport.close();
      worker.terminate();
    }

    // Wait for worker init acknowledgment (isolate_manager `initialized()`).
    // NOTE: this only confirms the worker scope is wired -- it does NOT confirm
    // the user `entrypoint` has run and subscribed its responder. We must wait
    // for the worker's own `ready` ack (sent after `entrypoint` returns) before
    // returning the transport, otherwise early RPC frames race ahead of the
    // responder subscription and are dropped (the bridge streams do not buffer).
    //
    // Failing here is FATAL, and deliberately so: not reaching this point means
    // the worker scope never came up at all, which no worker build has ever
    // done successfully. It is not the legacy-protocol case handled below.
    try {
      await awaitStartup(controller.ensureInitialized.future, 'initialization');
    } catch (_) {
      await abandon();
      rethrow;
    }

    // Listen for the worker's post-entrypoint readiness ack before any RPC
    // frames are allowed to flow.
    final ready = Completer<void>();
    final readySub = controller.onMessage.listen((raw) {
      final msg = _BridgeMessage.fromMap(raw);
      if (msg != null && msg.type == _BridgeType.ready && !ready.isCompleted) {
        ready.complete();
      }
    });

    // Deliver initial parameters to the worker.
    controller.sendIsolate(
      _BridgeMessage(
        type: _BridgeType.init,
        streamId: 0,
        payload: customParams ?? const <String, Object?>{},
      ).toMap(),
    );

    // Wait for the worker responder to be ready. A MISSING ack stays tolerated
    // on purpose -- a worker built before this protocol never sends one, and
    // hanging those would be a worse regression than the wait. But a worker
    // that ERRORS while we wait is not a legacy worker, and that case now
    // fails instead of being swallowed along with it.
    try {
      await Future.any([
        ready.future,
        workerFailed.future.then(
          (reason) => throw StateError(
            'RpcIsolateTransport.spawn: worker "$uri" failed before it was '
            'ready: $reason',
          ),
        ),
      ]).timeout(_readyGracePeriod, onTimeout: () {});
    } catch (_) {
      await readySub.cancel();
      await abandon();
      rethrow;
    }
    await readySub.cancel();

    // Past startup the worker is the peer, and a peer that dies must not look
    // healthy. The VM sibling closes its channel from onError/onExit; this is
    // the same, and without it `health()` answered "healthy / Transport ready"
    // for a worker that was gone and every call hung.
    worker.removeEventListener('error', errorListener);
    worker.removeEventListener('messageerror', errorListener);
    final deathListener = (Event event) {
      unawaited(transport.close());
    }.toJS;
    worker.addEventListener('error', deathListener);
    worker.addEventListener('messageerror', deathListener);

    void kill() {
      worker.removeEventListener('error', deathListener);
      worker.removeEventListener('messageerror', deathListener);
      unawaited(transport.close());
      worker.terminate();
    }

    return (transport: transport, kill: kill);
  }
}

/// Called from inside the worker entrypoint to wire up the RPC transport.
void runRpcIsolateManagerWorker(
  RpcIsolateEntrypoint entrypoint, {
  RpcSecurityPolicy policy = const RpcSecurityPolicy(),
}) {
  final scope = _workerSelf;

  final controller = IsolateManagerControllerImpl<Object?, Object?>(
    scope,
    onDispose: () => scope.close(),
  );

  final channel = _WebMultiplexedChannel(
    messageStream: controller.onIsolateMessage,
    send: controller.sendResult,
    onClose: () {
      controller.close();
      scope.close();
    },
  );
  final transport = RpcChannelTransport(
    channel: channel,
    isClient: false,
    policy: policy,
  );

  // Signal ready state.
  controller.initialized();

  void signalReady() {
    controller.sendResult(
      _BridgeMessage(type: _BridgeType.ready, streamId: 0).toMap(),
    );
  }

  controller.onIsolateMessage.first.then((raw) {
    try {
      final msg = _BridgeMessage.fromMap(raw);
      if (msg != null && msg.type == _BridgeType.init && msg.payload is Map) {
        final params = (msg.payload as Map).cast<String, dynamic>();
        entrypoint(transport, Map<String, dynamic>.from(params));
        // Ack readiness only AFTER the entrypoint has wired its responder, so
        // the host does not race RPC frames ahead of the subscription.
        signalReady();
        return;
      }
    } catch (_) {}
    try {
      entrypoint(transport, const <String, dynamic>{});
      signalReady();
    } catch (error, stackTrace) {
      unawaited(transport.close());
      Zone.current.handleUncaughtError(error, stackTrace);
    }
  });
}

// -- Helpers ------------------------------------------------------------------

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
      .map((header) => {'name': header.name, 'value': header.value})
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

WorkerOptions? _buildWorkerOptions(String? debugName) {
  if (!_kIsWasm && debugName == null) return null;
  if (_kIsWasm && debugName != null) {
    return WorkerOptions(type: 'module', name: debugName);
  }
  if (_kIsWasm) return WorkerOptions(type: 'module');
  return WorkerOptions(name: debugName!);
}

Uri _resolveWorkerUri(Uri? provided) {
  if (provided != null) return provided;
  final defaultPath = Uri.parse('$_defaultWorkerName.js');
  if (defaultPath.isAbsolute) return defaultPath;
  return Uri.base.resolveUri(defaultPath);
}
