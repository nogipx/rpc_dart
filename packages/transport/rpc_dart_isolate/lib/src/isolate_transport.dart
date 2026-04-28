// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';
import 'dart:isolate';

import 'package:rpc_dart/rpc_dart.dart';

// -- Internal message format --------------------------------------------------

enum _IsolateMessageType { init, metadata, data, directObject, finish, close }

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
  })  : _sendPort = sendPort,
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
      _sendPort.send(_IsolateMessage(
        type: type,
        streamId: message.streamId,
        data: data,
        isEndOfStream: message.isEndOfStream,
        methodPath: message.methodPath,
      ));
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
        if (message.streamId == 0) return;
        _incomingCtl.add(RpcTransportMessage(
          metadata: message.data as RpcMetadata,
          isEndOfStream: message.isEndOfStream,
          streamId: message.streamId,
          methodPath: message.methodPath,
        ));
      case _IsolateMessageType.data:
        if (message.streamId == 0) return;
        _incomingCtl.add(RpcTransportMessage(
          payload: _materializeBytes(message.data),
          isEndOfStream: message.isEndOfStream,
          streamId: message.streamId,
          methodPath: message.methodPath,
        ));
      case _IsolateMessageType.directObject:
        if (message.streamId == 0) return;
        _incomingCtl.add(RpcTransportMessage(
          streamId: message.streamId,
          isEndOfStream: message.isEndOfStream,
          directPayload: message.data,
        ));
      case _IsolateMessageType.finish:
        if (message.streamId == 0) return;
        _incomingCtl.add(RpcTransportMessage(
          isEndOfStream: true,
          streamId: message.streamId,
        ));
      case _IsolateMessageType.close:
        close();
      default:
        break;
    }
  }
}

// -- Public API ---------------------------------------------------------------

typedef RpcIsolateEntrypoint = void Function(
    IRpcTransport transport, Map<String, dynamic> customParams);

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
          final initMessage = await messageController.stream.firstWhere(
            (message) =>
                message is _IsolateMessage &&
                message.type == _IsolateMessageType.init,
          ) as _IsolateMessage;

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
        } catch (_) {
          if (!messageController.isClosed) {
            await messageController.close();
          }
          receivePort.close();
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

    late final StreamSubscription errorSub;
    late final StreamSubscription exitSub;

    errorSub = errorPort.listen((errorData) {
      // Remote isolate crashed -- close the channel.
      unawaited(hostChannel?.close());
    });

    exitSub = exitPort.listen((_) {
      // Remote isolate exited -- close the channel.
      unawaited(hostChannel?.close());
    });

    final workerSendPort = await initPort.first as SendPort;
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

    void killIsolate() {
      hostTransport?.close();
      isolate.kill(priority: Isolate.immediate);
      initPort.close();
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
