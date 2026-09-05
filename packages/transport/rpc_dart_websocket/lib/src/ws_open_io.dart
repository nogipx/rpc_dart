// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

/// Opens a WebSocket, applying [pingInterval] where the platform supports it.
///
/// The VM implementation, where [pingInterval] is real: dart:io sends a ping
/// every interval and CLOSES the connection when no pong comes back within
/// one. That close is the only thing that detects a half-open path — a NAT
/// box, load balancer or mobile network that silently stops forwarding, with
/// no FIN and no RST, leaving both peers believing the socket is fine.
///
/// Measured through a TCP relay that keeps both sockets open and stops copying
/// bytes, which is exactly what a dead path looks like:
///
///     no keepalive     : the call HUNG past 12s, health still "healthy"
///     pingInterval 2s  : RpcStatusException(14) after 4002ms, health "closed"
///     control (no freeze): returned in 5ms
///
/// Note the first line reports HEALTHY while the path is dead, so a supervisor
/// polling health sees green and every call waits out its deadline.
Future<WebSocketChannel> openWebSocket(
  Uri uri, {
  Iterable<String>? protocols,
  Duration? pingInterval,
}) async {
  final channel = IOWebSocketChannel.connect(
    uri,
    protocols: protocols,
    pingInterval: pingInterval,
  );
  await channel.ready;
  return channel;
}
