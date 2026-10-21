// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

/// The channel both isolate transports share. The VM and the web differ only
/// in how a frame, its bytes and its metadata cross the boundary.
///
/// Imports no `dart:isolate` and no JS library, so both platform files and an
/// ordinary VM test can load it.
library;

import 'dart:async';

import 'package:rpc_dart/transport.dart';

/// The function a spawned isolate or worker runs with its end of the
/// connection and the spawner's `customParams`.
typedef RpcIsolateEntrypoint =
    void Function(IRpcTransport transport, Map<String, dynamic> customParams);

/// Frame kinds the two sides exchange. On the web the wire name IS the enum
/// name, so renaming a value changes the protocol.
enum PortFrameType { init, ready, metadata, data, directObject, finish, close }

/// One frame, its body already in the port's form.
final class PortFrame {
  /// What kind of frame this is.
  final PortFrameType type;

  /// The RPC stream this frame belongs to; 0 is the handshake and the
  /// connection-level flow control.
  final int streamId;

  /// Whether this frame closes its stream.
  final bool endStream;

  /// The encoded metadata, bytes or object, as [type] says.
  final Object? body;

  /// The method this stream calls, carried on the opening frame.
  final String? methodPath;

  /// Creates a frame.
  const PortFrame({
    required this.type,
    required this.streamId,
    this.endStream = false,
    this.body,
    this.methodPath,
  });
}

/// An [IRpcMultiplexedChannel] over a message port: a stream of incoming
/// port messages and a function that posts one.
///
/// A subclass supplies the encoding: how a [PortFrame] becomes a port message
/// and back, and how bytes and metadata ride in its body.
abstract base class PortChannel extends IRpcMultiplexedChannel {
  final StreamController<RpcTransportMessage> _incomingCtl =
      StreamController<RpcTransportMessage>.broadcast(sync: true);
  late final StreamSubscription<void> _messageSub;
  bool _closed = false;
  final void Function()? _onClose;

  /// Reads frames from [messageStream]; [onClose] runs once the channel has
  /// closed.
  PortChannel({
    required Stream<dynamic> messageStream,
    void Function()? onClose,
  }) : _onClose = onClose {
    _messageSub = messageStream.listen(
      (raw) {
        final frame = decodeFrame(raw);
        if (frame != null) _handleFrame(frame);
      },
      onError: (_) {
        if (!_closed) close();
      },
      onDone: () {
        if (!_closed) close();
      },
    );
  }

  /// [frame] as a port message.
  Object encodeFrame(PortFrame frame);

  /// The frame [raw] carries, or null for a message that is not one.
  PortFrame? decodeFrame(Object? raw);

  /// [bytes] as a frame body.
  Object encodeBytes(Uint8List bytes);

  /// The bytes in a frame [body]. Throws for a body that holds none.
  Uint8List decodeBytes(Object? body);

  /// [metadata] as a frame body.
  Object encodeMetadata(RpcMetadata metadata);

  /// The metadata in a frame [body]. Throws for a body that holds none.
  RpcMetadata decodeMetadata(Object? body);

  /// Sends one port message. Throws only when [message] cannot cross.
  void post(Object message);

  /// Why [post] threw, for the error the sender sees.
  String get unsendable;

  @override
  bool get isClosed => _closed;

  @override
  Stream<RpcTransportMessage> get incoming => _incomingCtl.stream;

  @override
  Future<void> send(RpcTransportMessage message) async {
    if (_closed) return;

    final PortFrameType type;
    final Object? body;
    if (message.directPayload != null && supportsZeroCopy) {
      type = PortFrameType.directObject;
      body = message.directPayload;
    } else if (message.payload != null) {
      type = PortFrameType.data;
      body = encodeBytes(message.payload!);
    } else if (message.metadata != null) {
      type = PortFrameType.metadata;
      body = encodeMetadata(message.metadata!);
    } else if (message.isEndOfStream) {
      // RpcChannelTransport half-closes with `RpcMetadata([])`, which takes
      // the metadata branch. A bare end of stream still gets a frame rather
      // than being dropped.
      type = PortFrameType.finish;
      body = null;
    } else {
      return;
    }

    try {
      post(
        encodeFrame(
          PortFrame(
            type: type,
            streamId: message.streamId,
            endStream: message.isEndOfStream,
            body: body,
            methodPath: message.methodPath,
          ),
        ),
      );
    } catch (error, stack) {
      // ONE message's problem, not the connection's. A post throws for one
      // reason: the message cannot cross. A dead peer is SILENT -- a closed
      // port and a dead worker both accept the post and drop it. Closing the
      // channel here would kill every other in-flight call over one bad
      // payload.
      Error.throwWithStackTrace(
        ArgumentError(
          'Isolate transport: the message on stream ${message.streamId} '
          '$unsendable. $error',
        ),
        stack,
      );
    }
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;

    try {
      post(
        encodeFrame(const PortFrame(type: PortFrameType.close, streamId: 0)),
      );
    } catch (_) {}

    await _messageSub.cancel();
    if (!_incomingCtl.isClosed) await _incomingCtl.close();
    _onClose?.call();
  }

  void _handleFrame(PortFrame frame) {
    if (_closed || _incomingCtl.isClosed) return;
    if (frame.streamId < 0) return;
    // A frame that does not decode is reported on the stream, where the
    // transport fails the connection. Thrown here, in the data callback, it
    // is an uncaught zone error -- the end of an isolate spawned with
    // errorsAreFatal, or of a worker.
    try {
      _dispatch(frame);
    } catch (error, stackTrace) {
      if (!_incomingCtl.isClosed) _incomingCtl.addError(error, stackTrace);
    }
  }

  void _dispatch(PortFrame frame) {
    switch (frame.type) {
      case PortFrameType.metadata:
        // Stream 0 is NOT filtered here, unlike the payload cases below. The
        // handshake uses its own frame types, so metadata on stream 0 is
        // RpcChannelTransport's CONNECTION-level flow control. Drop it and the
        // peer looks like one that does not participate, leaving the
        // connection window off in BOTH directions.
        _incomingCtl.add(
          RpcTransportMessage(
            metadata: decodeMetadata(frame.body),
            isEndOfStream: frame.endStream,
            streamId: frame.streamId,
            methodPath: frame.methodPath,
          ),
        );
      case PortFrameType.data:
        if (frame.streamId == 0) return;
        _incomingCtl.add(
          RpcTransportMessage(
            payload: decodeBytes(frame.body),
            isEndOfStream: frame.endStream,
            streamId: frame.streamId,
            methodPath: frame.methodPath,
          ),
        );
      case PortFrameType.directObject:
        if (frame.streamId == 0 || !supportsZeroCopy) return;
        _incomingCtl.add(
          RpcTransportMessage(
            streamId: frame.streamId,
            isEndOfStream: frame.endStream,
            directPayload: frame.body,
          ),
        );
      case PortFrameType.finish:
        if (frame.streamId == 0) return;
        _incomingCtl.add(
          RpcTransportMessage(isEndOfStream: true, streamId: frame.streamId),
        );
      case PortFrameType.close:
        close();
      case PortFrameType.init:
      case PortFrameType.ready:
        // The handshake, consumed by spawn() and the worker before the
        // channel carries calls.
        break;
    }
  }
}
