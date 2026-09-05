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
Future<WebSocketChannel> openWebSocket(
  Uri uri, {
  Iterable<String>? protocols,
  Duration? pingInterval,
}) async {
  final channel = WebSocketChannel.connect(uri, protocols: protocols);
  await channel.ready;
  return channel;
}
