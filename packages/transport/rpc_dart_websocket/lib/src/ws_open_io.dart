// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:io';

import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

/// Opens a WebSocket, applying [pingInterval] where the platform supports it.
///
/// The VM implementation, where [pingInterval] is real: dart:io pings every
/// interval and CLOSES the connection when no pong returns within one. That
/// close is the only thing that detects a half-open path — a NAT box, load
/// balancer or mobile network that silently stops forwarding, with no FIN and
/// no RST. Without it a call on a dead path hangs to its deadline while
/// `health()` still reports healthy, so a supervisor polling health sees green.
///
/// [enableCompression] controls whether the client OFFERS permessage-deflate,
/// and is false by default, mirroring the server default in
/// `rpcWebSocketConnections`. The extension is a decompression bomb on the
/// RECEIVING side: dart:io inflates an incoming message with no output bound
/// before rpc_dart can see it, so a hostile or compromised server that
/// negotiates it turns a fraction of a MiB on the wire into hundreds of MiB of
/// client RSS. A client that never offers it cannot be flooded that way. Turn
/// it on only against servers you control and trust.
///
/// The raw dart:io WebSocket is opened here rather than through
/// [IOWebSocketChannel.connect], which passes no compression argument and so
/// always takes dart:io's default (ON).
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
