// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';

import 'package:web_socket_channel/web_socket_channel.dart';

/// Whether THIS platform's `openWebSocket` actually applies `pingInterval`.
///
/// FALSE here, and that is the gap this constant exists to close. A browser runs
/// ping/pong inside its own WebSocket implementation and exposes neither the
/// interval nor the outcome, so a missing pong never reaches the page. Measured
/// against a peer that completes the handshake and then goes silent, at a 300 ms
/// interval:
///
///     dart:io, honours it   626ms to notice
///     here, drops it        NEVER (capped at 5s)
///
/// `RpcWebSocketCallerTransport` reads this to decide whether it must run an
/// application-level heartbeat instead.
const bool platformHonoursPingInterval = false;

/// Opens a WebSocket, applying [pingInterval] where the platform supports it.
///
/// The portable fallback and the WEB implementation both. [pingInterval] is
/// accepted and IGNORED HERE: a browser runs ping/pong inside its WebSocket
/// implementation and exposes neither the interval nor the outcome, so a
/// missing pong does not surface to the page and does not close the socket the
/// way `dart:io` does. **Ignored here does not mean lost** —
/// [platformHonoursPingInterval] is how `RpcWebSocketCallerTransport` learns to
/// run the library's own ping at that cadence instead. Change one without the
/// other and the web arm is blind again.
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
/// [maxMessageBytes] is accepted and ignored: the browser assembles each
/// message itself, before the page sees a byte.
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
  int? maxMessageBytes,
}) async {
  // Referenced so the analyzer does not flag them, and so a reader sees the
  // platform cannot honour them rather than that somebody forgot. pingInterval
  // belongs here too: it is the one whose absence actually costs something.
  final _ = (pingInterval, enableCompression, headers, maxMessageBytes);
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
