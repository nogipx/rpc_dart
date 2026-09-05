// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:io';

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
///
/// [enableCompression] controls whether the client OFFERS permessage-deflate.
/// It defaults to false, the mirror of the server default (see
/// `rpcWebSocketConnections`): the extension is a decompression bomb on the
/// RECEIVING side, and dart:io inflates an incoming message with no output
/// bound before rpc_dart can see it. A client that does not offer the extension
/// cannot have a hostile or compromised server negotiate it and flood the
/// client. Measured against a server that answered with a 256 MiB payload of
/// zeros: offering it, 0.25 MiB on the wire inflated to 248 MiB of client RSS
/// (995x); not offering it, the server cannot compress at all. Turn it on only
/// against servers you control and trust.
///
/// [IOWebSocketChannel.connect] passes no compression argument, so it always
/// used dart:io's default (ON); this opens the raw dart:io WebSocket directly to
/// take control of it.
Future<WebSocketChannel> openWebSocket(
  Uri uri, {
  Iterable<String>? protocols,
  Duration? pingInterval,
  bool enableCompression = false,
}) async {
  final webSocket = await WebSocket.connect(
    uri.toString(),
    protocols: protocols,
    compression: enableCompression
        ? CompressionOptions.compressionDefault
        : CompressionOptions.compressionOff,
  );
  webSocket.pingInterval = pingInterval;
  final channel = IOWebSocketChannel(webSocket);
  await channel.ready;
  return channel;
}
