// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:io';

import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

/// Turns an [HttpServer] into the `Stream<WebSocketChannel>` that
/// `RpcWebSocketServer` consumes, applying server-side keepalive.
///
/// [pingInterval] is why this exists. A server cannot set it any other way:
/// `RpcWebSocketServer` and `RpcWebSocketResponderTransport` are handed an
/// already-built [WebSocketChannel], and neither `IOWebSocketChannel` nor the
/// `WebSocketChannel` interface exposes the underlying socket. The interval has
/// to be set on the dart:io [WebSocket] between the upgrade and the wrap, which
/// is exactly the seam this function owns.
///
/// Without it a server keeps every half-open connection forever. A client whose
/// network vanishes sends no FIN and no RST, so the server's socket still looks
/// fine. Measured with a TCP relay frozen mid-flight and the clients abandoned
/// without closing, counting the server's live endpoints and the `dispose()`
/// calls on the contracts they hold:
///
///     no keepalive      : endpoints 5, contracts disposed 0 -- unchanged at
///                         t+30s, and nothing would ever reclaim them
///     pingInterval 3s   : endpoints 0, contracts disposed 5 by t+10s
///
/// That second number is the one that matters: an endpoint holds the
/// application's contracts, and a contract that is never disposed keeps
/// whatever it owns -- database handles, caches, subscriptions -- for the life
/// of the process. A fleet of mobile clients on flaky networks accumulates
/// them.
///
/// Left to the caller rather than defaulted, for the same reason as the client
/// side: too short wakes radios and wastes battery, too long leaves dead
/// connections resident. Take the shortest idle timeout on the path -- load
/// balancers commonly use 60s -- and halve it.
///
/// ```dart
/// final http = await HttpServer.bind(host, port);
/// final server = RpcWebSocketServer(
///   connections: rpcWebSocketConnections(
///     http,
///     pingInterval: const Duration(seconds: 30),
///   ),
///   onEndpointCreated: ...,
/// );
/// ```
///
/// [protocolSelector] is forwarded to [WebSocketTransformer] for subprotocol
/// negotiation; [compression] likewise, defaulting to dart:io's default.
Stream<WebSocketChannel> rpcWebSocketConnections(
  HttpServer server, {
  Duration? pingInterval,
  dynamic Function(List<String> protocols)? protocolSelector,
  CompressionOptions compression = CompressionOptions.compressionDefault,
}) {
  return server
      .transform(
        WebSocketTransformer(
          protocolSelector: protocolSelector,
          compression: compression,
        ),
      )
      .map((socket) {
        // Set BEFORE wrapping: once inside IOWebSocketChannel the socket is no
        // longer reachable.
        socket.pingInterval = pingInterval;
        return IOWebSocketChannel(socket);
      });
}
