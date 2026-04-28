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
    if (!_incoming.isClosed) await _incoming.close();
  }
}
