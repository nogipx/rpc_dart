// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';
import 'dart:io';

import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

/// A [WebSocketChannel] over a dart:io [socket] that its caller keeps and may
/// close itself — a server that upgraded it and closes every socket on stop.
///
/// Closed out from under a channel while a frame is on its way, the socket
/// refuses the write with `Bad state: StreamSink is closed`, thrown in the zone
/// the channel was built in, where nothing can catch it: in the root zone it
/// ends the isolate (see `RpcWebSocketChannel`). This builds the channel in a
/// zone of its own where that one error is dropped, since the socket it was
/// for is gone and there is nowhere left to deliver it. Every other error the
/// channel throws goes on to the zone this was called in, as it would have.
///
/// ```dart
/// final socket = await WebSocketTransformer.upgrade(request);
/// final transport = RpcWebSocketResponderTransport(rpcWebSocketChannel(socket));
/// // ...later, on stop: safe even with calls in flight.
/// await socket.close();
/// ```
///
/// A channel the library builds (`RpcWebSocketCallerTransport.connect`,
/// `rpcWebSocketConnections`) never hands its socket out, so it needs none of
/// this.
WebSocketChannel rpcWebSocketChannel(WebSocket socket) {
  final caller = Zone.current;
  late final WebSocketChannel channel;
  runZonedGuarded(() => channel = IOWebSocketChannel(socket), (error, stack) {
    if (_writeToAClosedSocket(error)) return;
    caller.handleUncaughtError(error, stack);
  });
  return channel;
}

/// The refusal dart:io's socket gives a write after it was closed.
bool _writeToAClosedSocket(Object error) =>
    error is StateError && error.message == 'StreamSink is closed';
