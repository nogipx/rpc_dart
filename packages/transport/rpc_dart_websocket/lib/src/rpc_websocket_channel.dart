// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

/// [IRpcChannel] implementation wrapping a [WebSocketChannel].
///
/// Converts the WebSocket message stream into a raw byte pipe.
/// Combine with [RpcChannelTransport.fromChannel] to get a full
/// [IRpcTransport] with multiplexing, security, and health checks.
///
/// ```dart
/// final wsChannel = WebSocketChannel.connect(uri);
/// final transport = RpcChannelTransport.fromChannel(
///   channel: RpcWebSocketChannel(wsChannel),
///   isClient: true,
/// );
/// ```
class RpcWebSocketChannel implements IRpcChannel {
  final WebSocketChannel _ws;
  final StreamController<Uint8List> _incoming = StreamController<Uint8List>();
  late final StreamSubscription _sub;
  bool _closed = false;

  RpcWebSocketChannel(this._ws) {
    _sub = _ws.stream.listen(
      (data) {
        if (_incoming.isClosed) return;
        if (data is Uint8List) {
          _incoming.add(data);
        } else if (data is List<int>) {
          _incoming.add(Uint8List.fromList(data));
        } else {
          // Anything that is not binary -- in practice a WebSocket TEXT frame,
          // which arrives as a String. This protocol is binary-only, so a text
          // frame is a peer error.
          //
          // It used to fall through both branches and vanish: measured against
          // a real dart:io WebSocket server, sending a text frame left
          // `connectionClosed=false error=none` and the peer got no signal at
          // all, so a call made over that connection simply hung until its
          // deadline. Silent loss is the worst of the options -- nothing to
          // see in a log, nothing on the wire.
          //
          // Reported rather than fatal. The error travels
          // RpcFrameMultiplexedChannel -> RpcChannelTransport -> the endpoint's
          // incoming stream, where it is logged, and the connection stays
          // usable for the binary frames around it. Closing instead would turn
          // one stray frame -- an app-level keepalive from a proxy, say -- into
          // a dropped connection, which is a bigger change than the defect
          // being fixed here.
          _incoming.addError(
            RpcException(
              'RpcWebSocketChannel: expected a binary WebSocket message, got '
              '${data.runtimeType}. This transport is binary-only; a text '
              'frame cannot carry an RPC frame and was discarded.',
            ),
          );
        }
      },
      onError: (Object e) {
        if (!_incoming.isClosed) _incoming.addError(e);
      },
      onDone: () {
        if (!_closed) close();
      },
    );
  }

  @override
  bool get isClosed => _closed;

  @override
  Stream<Uint8List> get incoming => _incoming.stream;

  @override
  Future<void> send(Uint8List data) async {
    if (_closed) return;
    _ws.sink.add(data);
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _sub.cancel();
    try {
      await _ws.sink.close();
    } catch (_) {}
    // NOT awaited. `_incoming` is single-subscription, and closing one that
    // was never listened to returns a future that does not complete until
    // someone listens -- so `await` here deadlocked close() outright.
    //
    // The normal path is safe because RpcFrameMultiplexedChannel subscribes in
    // its constructor. The path that is not is closing a channel that was
    // built but never wrapped: an aborted setup, or an error between
    // construction and use -- exactly when cleanup has to work. This class is
    // public and documented for direct construction, so that is reachable.
    //
    // Measured, with a listener as the control:
    //   no listener : close() still pending after 3s, forever
    //   listener    : close() returns
    //
    // Same fault as the CONNECT-proxy deadlock in dcc14f8c. Broadcast would
    // also "fix" it and must NOT be used: a broadcast controller DROPS events
    // that arrive before the frame channel subscribes, where this one buffers
    // them.
    if (!_incoming.isClosed) unawaited(_incoming.close());
  }
}
