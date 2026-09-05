// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'package:web_socket_channel/web_socket_channel.dart';

/// Opens a WebSocket, applying [pingInterval] where the platform supports it.
///
/// This is the portable fallback and the WEB implementation both: browsers run
/// ping/pong inside the WebSocket implementation and expose no API for it, so
/// [pingInterval] is accepted and ignored rather than being an error. A web
/// client is not left unprotected by that — the browser is doing it — it just
/// cannot be tuned from here.
///
/// [enableCompression] is likewise accepted and ignored: the browser negotiates
/// permessage-deflate itself and exposes no API to disable it, so a web client
/// can neither turn it off here nor be protected here from a hostile server's
/// decompression bomb — that is the browser's memory to manage. The parameter
/// exists so the cross-platform signature matches the dart:io implementation,
/// where it IS honoured.
Future<WebSocketChannel> openWebSocket(
  Uri uri, {
  Iterable<String>? protocols,
  Duration? pingInterval,
  bool enableCompression = false,
}) async {
  final _ = enableCompression;
  final channel = WebSocketChannel.connect(uri, protocols: protocols);
  await channel.ready;
  return channel;
}
