// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';
import 'dart:isolate';

import 'package:rpc_dart/rpc_dart.dart';

// -- Internal message format --------------------------------------------------

enum _IsolateMessageType {
  init,
  ready,
  metadata,
  data,
  directObject,
  finish,
  close,
}

class _IsolateMessage {
  final _IsolateMessageType type;
  final dynamic data;
  final bool isEndOfStream;
  final int streamId;
  final String? methodPath;

  _IsolateMessage({
    required this.type,
    required this.streamId,
    this.data,
    this.isEndOfStream = false,
    this.methodPath,
  });
}

// -- Multiplexed channel over SendPort/ReceivePort ----------------------------

/// [IRpcMultiplexedChannel] backed by Dart isolate [SendPort]/[ReceivePort].
///
/// Supports zero-copy object passing and [TransferableTypedData] for bytes.
/// Used internally by [RpcIsolateTransport.spawn] -- not intended for direct use.
class _IsolateMultiplexedChannel implements IRpcMultiplexedChannel {
  final SendPort _sendPort;
  final StreamController<RpcTransportMessage> _incomingCtl =
      StreamController<RpcTransportMessage>.broadcast(sync: true);
  late final StreamSubscription _messageSub;
  bool _closed = false;
  final void Function()? _onClose;

  _IsolateMultiplexedChannel({
    required SendPort sendPort,
    required Stream<dynamic> messageStream,
    void Function()? onClose,
  }) : _sendPort = sendPort,
       _onClose = onClose {
    _messageSub = messageStream.listen(
      _handleMessage,
      onDone: () {
        if (!_closed) close();
      },
    );
  }

  @override
  bool get isClosed => _closed;

  @override
  bool get supportsZeroCopy => true;

  @override
  Stream<RpcTransportMessage> get incoming => _incomingCtl.stream;

  @override
  Future<void> send(RpcTransportMessage message) async {
    if (_closed) return;

    _IsolateMessageType type;
    dynamic data;

    if (message.directPayload != null) {
      type = _IsolateMessageType.directObject;
      data = message.directPayload;
    } else if (message.payload != null) {
      type = _IsolateMessageType.data;
      data = TransferableTypedData.fromList([message.payload!]);
    } else if (message.metadata != null) {
      type = _IsolateMessageType.metadata;
      data = message.metadata;
    } else if (message.isEndOfStream) {
      type = _IsolateMessageType.finish;
      data = null;
    } else {
      return;
    }

    try {
      _sendPort.send(
        _IsolateMessage(
          type: type,
          streamId: message.streamId,
          data: data,
          isEndOfStream: message.isEndOfStream,
          methodPath: message.methodPath,
        ),
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
      _sendPort.send(
        _IsolateMessage(type: _IsolateMessageType.close, streamId: 0),
      );
    } catch (_) {}

    await _messageSub.cancel();
    if (!_incomingCtl.isClosed) await _incomingCtl.close();
    _onClose?.call();
  }

  void _handleMessage(dynamic message) {
    if (message is! _IsolateMessage || _closed || _incomingCtl.isClosed) return;
    if (message.streamId < 0) return;

    switch (message.type) {
      case _IsolateMessageType.metadata:
        // Stream 0 is NOT filtered here, unlike the payload cases below.
        //
        // This transport reserves stream 0 for its own init/ready/close
        // handshake, and those are distinct enum types -- so a `metadata` frame
        // on stream 0 is never a handshake message. It is what
        // RpcChannelTransport uses for CONNECTION-level flow control
        // (x-rpc-conn-window-update), and dropping it here made the peer look
        // like one that does not participate in flow control, leaving the
        // connection window off in both directions. Neither of core's own
        // channels filters stream 0; this one did.
        _incomingCtl.add(
          RpcTransportMessage(
            metadata: message.data as RpcMetadata,
            isEndOfStream: message.isEndOfStream,
            streamId: message.streamId,
            methodPath: message.methodPath,
          ),
        );
      case _IsolateMessageType.data:
        if (message.streamId == 0) return;
        _incomingCtl.add(
          RpcTransportMessage(
            payload: _materializeBytes(message.data),
            isEndOfStream: message.isEndOfStream,
            streamId: message.streamId,
            methodPath: message.methodPath,
          ),
        );
      case _IsolateMessageType.directObject:
        if (message.streamId == 0) return;
        _incomingCtl.add(
          RpcTransportMessage(
            streamId: message.streamId,
            isEndOfStream: message.isEndOfStream,
            directPayload: message.data,
          ),
        );
      case _IsolateMessageType.finish:
        if (message.streamId == 0) return;
        _incomingCtl.add(
          RpcTransportMessage(isEndOfStream: true, streamId: message.streamId),
        );
      case _IsolateMessageType.close:
        close();
      case _IsolateMessageType.init:
      case _IsolateMessageType.ready:
        // Handshake-level control messages: consumed during spawn(), not data.
        break;
    }
  }
}

// -- Public API ---------------------------------------------------------------

typedef RpcIsolateEntrypoint =
    void Function(IRpcTransport transport, Map<String, dynamic> customParams);

/// Factory for spawning an isolate with an [IRpcTransport] on each side.
///
/// The host side gets a client transport (odd stream IDs), the worker side
/// gets a server transport (even stream IDs). Both are backed by
/// [RpcChannelTransport] wrapping an [_IsolateMultiplexedChannel].
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
    final name = debugName ?? 'rpc-isolate-$isolateId';

    void entrypointWrapper(List<dynamic> args) {
      final hostSendPort = args[0] as SendPort;
      final customParams = args[2] as Map<String, dynamic>;
      final userEntrypoint = args[3] as RpcIsolateEntrypoint;
      final policy = RpcSecurityPolicy.fromMap(
        (args[4] as Map).cast<String, Object?>(),
      );

      final receivePort = ReceivePort();
      final messageController = StreamController<dynamic>.broadcast();

      receivePort.listen(
        (message) {
          if (messageController.isClosed) return;

          if (message is _IsolateMessage &&
              message.type == _IsolateMessageType.close &&
              message.streamId == 0) {
            messageController.add(message);
            receivePort.close();
            if (!messageController.isClosed) messageController.close();
            return;
          }

          messageController.add(message);
        },
        onDone: () {
          if (!messageController.isClosed) messageController.close();
        },
      );

      hostSendPort.send(receivePort.sendPort);

      () async {
        try {
          final initMessage =
              await messageController.stream.firstWhere(
                    (message) =>
                        message is _IsolateMessage &&
                        message.type == _IsolateMessageType.init,
                  )
                  as _IsolateMessage;

          final mainHostSendPort = initMessage.data as SendPort;

          final channel = _IsolateMultiplexedChannel(
            sendPort: mainHostSendPort,
            messageStream: messageController.stream,
            onClose: () {
              receivePort.close();
              if (!messageController.isClosed) messageController.close();
            },
          );
          final transport = RpcChannelTransport(
            channel: channel,
            isClient: false,
            policy: policy,
          );

          userEntrypoint(transport, customParams);

          // Signal that the worker started successfully. The host blocks its
          // spawn() return on this ack, so a worker that crashes during
          // startup makes spawn() throw (via onError/onExit) instead of
          // returning a silently-dead transport.
          mainHostSendPort.send(
            _IsolateMessage(type: _IsolateMessageType.ready, streamId: 0),
          );
        } catch (error, stack) {
          // Do not swallow worker-startup failures: rethrow so the isolate
          // terminates with an uncaught error, which the host observes via its
          // onError port (surfacing the real cause instead of a hang).
          if (!messageController.isClosed) {
            await messageController.close();
          }
          receivePort.close();
          Error.throwWithStackTrace(error, stack);
        }
      }();
    }

    final initPort = ReceivePort();
    final errorPort = ReceivePort();
    final exitPort = ReceivePort();

    final isolate = await Isolate.spawn(
      entrypointWrapper,
      [
        initPort.sendPort,
        isolateId,
        customParams ?? {},
        entrypoint,
        policy.toMap(),
      ],
      debugName: name,
      onError: errorPort.sendPort,
      onExit: exitPort.sendPort,
    );

    _IsolateMultiplexedChannel? hostChannel;
    RpcChannelTransport? hostTransport;

    late final StreamSubscription initSub;
    late final StreamSubscription errorSub;
    late final StreamSubscription exitSub;

    // Race the handshake (worker's SendPort) against an isolate error/exit
    // before handshake and a startup timeout, so spawn() fails fast and
    // informatively instead of hanging forever.
    final handshake = Completer<SendPort>();

    void completeError(Object error, [StackTrace? stack]) {
      if (!handshake.isCompleted) {
        handshake.completeError(error, stack ?? StackTrace.current);
      }
    }

    initSub = initPort.listen((message) {
      if (message is SendPort && !handshake.isCompleted) {
        handshake.complete(message);
      }
    });

    // Completed once the worker acks readiness (or fails) during startup.
    // Until completed, an isolate error/exit aborts spawn() with the cause.
    final ready = Completer<void>();

    void abortStartup(Object error, [StackTrace? stack]) {
      if (!handshake.isCompleted) {
        completeError(error, stack);
      } else if (!ready.isCompleted) {
        ready.completeError(error, stack ?? StackTrace.current);
      }
    }

    String describeError(Object? errorData) {
      if (errorData is List && errorData.isNotEmpty) {
        return errorData[0]?.toString() ?? 'unknown error';
      }
      return 'unknown error';
    }

    StackTrace? stackFromError(Object? errorData) {
      if (errorData is List && errorData.length > 1 && errorData[1] != null) {
        return StackTrace.fromString(errorData[1].toString());
      }
      return null;
    }

    errorSub = errorPort.listen((errorData) {
      // The onError port delivers [errorString, stackTraceString].
      if (!ready.isCompleted) {
        abortStartup(
          StateError(
            'RpcIsolateTransport.spawn: isolate "$name" threw before it was '
            'ready: ${describeError(errorData)}',
          ),
          stackFromError(errorData),
        );
        return;
      }
      // Remote isolate crashed after startup -- close the channel.
      unawaited(hostChannel?.close());
    });

    exitSub = exitPort.listen((_) {
      if (!ready.isCompleted) {
        abortStartup(
          StateError(
            'RpcIsolateTransport.spawn: isolate "$name" exited before it was '
            'ready.',
          ),
        );
        return;
      }
      // Remote isolate exited after startup -- close the channel.
      unawaited(hostChannel?.close());
    });

    Future<void> teardownStartup() async {
      isolate.kill(priority: Isolate.immediate);
      await initSub.cancel();
      await errorSub.cancel();
      await exitSub.cancel();
      initPort.close();
      errorPort.close();
      exitPort.close();
    }

    final SendPort workerSendPort;
    try {
      workerSendPort = await handshake.future.timeout(
        startupTimeout,
        onTimeout: () => throw TimeoutException(
          'RpcIsolateTransport.spawn: isolate "$name" did not complete the '
          'handshake within $startupTimeout.',
          startupTimeout,
        ),
      );
    } catch (_) {
      // First handshake failed (error / exit / timeout). Tear everything down
      // so a stuck or crashed isolate and its ports/subscriptions do not leak.
      await teardownStartup();
      rethrow;
    }

    // First handshake done: the init port has served its purpose.
    await initSub.cancel();
    initPort.close();

    final hostReceivePort = ReceivePort();

    workerSendPort.send(
      _IsolateMessage(
        type: _IsolateMessageType.init,
        streamId: 0,
        data: hostReceivePort.sendPort,
      ),
    );

    final messageController = StreamController<dynamic>.broadcast();
    hostReceivePort.listen(
      (message) {
        if (message is _IsolateMessage &&
            message.type == _IsolateMessageType.ready &&
            message.streamId == 0) {
          if (!ready.isCompleted) ready.complete();
          return;
        }

        if (messageController.isClosed) return;

        if (message is _IsolateMessage &&
            message.type == _IsolateMessageType.close &&
            message.streamId == 0) {
          messageController.add(message);
          hostReceivePort.close();
          if (!messageController.isClosed) messageController.close();
          return;
        }

        messageController.add(message);
      },
      onDone: () {
        if (!messageController.isClosed) messageController.close();
      },
    );

    // Attach the channel and the transport BEFORE waiting for `ready`.
    //
    // `messageController` is a plain broadcast controller, so anything added to
    // it while nobody is listening is discarded -- and the worker starts
    // sending well before it acks readiness. Its RpcChannelTransport advertises
    // the connection window from its constructor, and the user entrypoint runs
    // after that but still before the ack, so every frame either produces was
    // dropped on the floor here.
    //
    // The window grant is the one that is always lost: without it the host's
    // connection credit stays null, which reads as "the peer does not
    // participate in flow control", so host -> worker sends were UNBOUNDED for
    // the life of every isolate connection.
    //
    // Buffering the raw controller is not enough: it would flush synchronously
    // inside `listen()`, i.e. from _IsolateMultiplexedChannel's constructor,
    // into an _incomingCtl that RpcChannelTransport has not subscribed to yet.
    // Subscribing early instead closes the window at both hops -- the two
    // constructions below are synchronous and back to back, so no port message
    // can land between them.
    hostChannel = _IsolateMultiplexedChannel(
      sendPort: workerSendPort,
      messageStream: messageController.stream,
      onClose: () {
        hostReceivePort.close();
        if (!messageController.isClosed) messageController.close();
      },
    );
    hostTransport = RpcChannelTransport(
      channel: hostChannel,
      isClient: true,
      policy: policy,
    );

    // Wait for the worker to confirm it started (its entrypoint ran without
    // throwing). A crash/exit before this resolves makes spawn() throw rather
    // than return a silently-dead transport.
    try {
      await ready.future.timeout(
        startupTimeout,
        onTimeout: () => throw TimeoutException(
          'RpcIsolateTransport.spawn: isolate "$name" did not become ready '
          'within $startupTimeout.',
          startupTimeout,
        ),
      );
    } catch (_) {
      // Closing the transport closes the channel, whose onClose closes the
      // receive port and the raw controller -- the cleanup this path used to
      // do by hand, now that it owns both.
      await hostTransport.close();
      await teardownStartup();
      rethrow;
    }

    void killIsolate() {
      hostTransport?.close();
      isolate.kill(priority: Isolate.immediate);
      // initPort / initSub already closed after a successful handshake.
      errorPort.close();
      exitPort.close();
      errorSub.cancel();
      exitSub.cancel();
    }

    return (transport: hostTransport, kill: killIsolate);
  }
}

// -- Helpers ------------------------------------------------------------------

Uint8List _materializeBytes(dynamic data) {
  if (data is TransferableTypedData) {
    return data.materialize().asUint8List();
  }
  if (data is Uint8List) {
    return data;
  }
  throw StateError(
    'Unsupported data type for isolate message payload: ${data.runtimeType}',
  );
}

/// Web stub -- overridden by isolate_transport_web.dart on JS platforms.
void runRpcIsolateManagerWorker(
  RpcIsolateEntrypoint entrypoint, {
  RpcSecurityPolicy policy = const RpcSecurityPolicy(),
}) {}
