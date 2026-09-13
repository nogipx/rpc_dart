// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';

import 'package:web_socket_channel/web_socket_channel.dart';

/// Opens a WebSocket, applying [pingInterval] where the platform supports it.
///
/// The portable fallback and the WEB implementation both. [pingInterval] is
/// accepted and IGNORED: browsers run ping/pong inside the WebSocket
/// implementation and expose no API for it, so a web client is not left
/// unprotected — the browser is doing it — it just cannot be tuned from here.
///
/// [enableCompression] is likewise accepted and ignored: the browser negotiates
/// permessage-deflate itself, so a web client can neither turn it off here nor
/// be protected here from a hostile server's decompression bomb — that is the
/// browser's memory to manage.
///
/// [headers] are accepted and IGNORED, and this one is a hard browser limit
/// rather than a gap: the WebSocket API takes no request headers at all, so a
/// browser client authenticates with a cookie, a `Sec-WebSocket-Protocol` value
/// (see [protocols]) or a query parameter. Ignored rather than rejected so one
/// piece of cross-platform code can pass a token that the VM honours — throwing
/// here would make every such program branch on the platform.
///
/// [connectTimeout] IS honoured here: the bound is around `ready`, which needs
/// no platform API. Every parameter exists so the signature matches the dart:io
/// implementation; which of them bite differs, and is stated per parameter.
Future<WebSocketChannel> openWebSocket(
  Uri uri, {
  Iterable<String>? protocols,
  Duration? pingInterval,
  bool enableCompression = false,
  Map<String, Object>? headers,
  Duration? connectTimeout,
}) async {
  // Referenced so the analyzer does not flag them, and so a reader sees the
  // platform cannot honour them rather than that somebody forgot.
  final _ = (enableCompression, headers);
  final channel = WebSocketChannel.connect(uri, protocols: protocols);
  final ready = connectTimeout == null
      ? channel.ready
      : channel.ready.timeout(
          connectTimeout,
          onTimeout: () {
            // Nothing to leak on the way out: unlike dart:io there is no raw
            // socket held apart from the channel, so closing it is the whole
            // cleanup.
            unawaited(channel.sink.close().catchError((_) {}));
            throw TimeoutException(
              'WebSocket connect to $uri timed out',
              connectTimeout,
            );
          },
        );
  await ready;
  return channel;
}
