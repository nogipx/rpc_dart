// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';
import 'dart:io';

import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

/// Turns an [HttpServer] into the `Stream<WebSocketChannel>` that
/// `RpcWebSocketServer` consumes, applying server-side keepalive.
///
/// Exists because the dart:io [WebSocket] is only reachable between the upgrade
/// and the wrap — `IOWebSocketChannel` hides it.
///
/// [pingInterval] defaults to 30s, and an idle connection is pinged and closed
/// if no pong comes. Without it a peer that completes the upgrade and goes
/// silent holds its endpoint, and the contracts on it, forever:
/// `HttpServer.idleTimeout` does not reach an upgraded socket. Pass `null` to
/// disable; raise it where radio wake-ups matter.
///
/// [protocolSelector] is forwarded to [WebSocketTransformer] for subprotocol
/// negotiation.
///
/// [compression] defaults to OFF where dart:io's default is ON. dart:io
/// inflates each message with no output limit before rpc_dart sees it, so
/// [RpcSecurityPolicy.maxMessageLengthBytes] cannot bound it and a few hundred
/// KiB on the wire can peak at hundreds of MiB of RSS. Turn it on only between
/// peers you control.
///
/// [allowedOrigins] refuses cross-origin handshakes. WebSocket is not subject
/// to the same-origin policy, so a browser page will open a socket anywhere and
/// attach ambient credentials; checking `Origin` at the handshake is the only
/// protocol-level defence. Compared case-insensitively against the whole origin
/// (`scheme://host[:port]`).
///
/// A request with NO `Origin` is ALLOWED even when this is set — every
/// non-browser client sends none, and the attack being stopped is a browser
/// riding cookies it cannot read. More than one `Origin` header is refused.
///
/// [allowUpgrade] runs after [allowedOrigins]; both must accept. Synchronous on
/// purpose — it is in the accept path, where an await serializes every
/// handshake. If it throws the connection is refused and the server lives: the
/// accept loop is the ROOT ZONE, where an escaping error kills the isolate.
///
/// A refused request is answered `403` and never upgraded.
///
/// ```dart
/// final http = await HttpServer.bind(host, port);
/// final server = RpcWebSocketServer(
///   connections: rpcWebSocketConnections(
///     http,
///     allowedOrigins: {'https://app.example.com'},
///   ),
///   onEndpointCreated: ...,
/// );
/// ```
Stream<WebSocketChannel> rpcWebSocketConnections(
  HttpServer server, {
  Duration? pingInterval = const Duration(seconds: 30),
  dynamic Function(List<String> protocols)? protocolSelector,
  CompressionOptions compression = CompressionOptions.compressionOff,
  Set<String>? allowedOrigins,
  bool Function(HttpRequest request)? allowUpgrade,
}) {
  // Filtered BEFORE the transformer rather than after: once WebSocketTransformer
  // has upgraded the request the response is already committed, and the only
  // thing left to do would be to close a socket the peer believes is open.
  final gated = allowedOrigins == null && allowUpgrade == null
      ? server
      : server.where((request) {
          // This runs inside the accept loop's event handler, which is the ROOT
          // ZONE: anything thrown here is an unhandled async error and kills
          // the isolate -- unauthenticated, in one request. The origin read is
          // safe now, but [allowUpgrade] is USER code and cannot be, so failing
          // closed keeps a throwing predicate to a refused connection instead
          // of a dead server.
          bool allowed;
          try {
            allowed = _upgradeAllowed(request, allowedOrigins, allowUpgrade);
          } catch (_) {
            allowed = false;
          }
          if (allowed) return true;
          _refuse(request);
          return false;
        });

  return gated
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

bool _upgradeAllowed(
  HttpRequest request,
  Set<String>? allowedOrigins,
  bool Function(HttpRequest request)? allowUpgrade,
) {
  if (allowedOrigins != null) {
    // `headers[...]`, not `headers.value(...)`: dart:io's `value()` THROWS
    // HttpException when a header carries more than one value, and this runs
    // in the root zone (see the caller).
    final origins = request.headers['origin'];

    // Absent means a non-browser client; see the doc on [allowedOrigins].
    if (origins != null && origins.isNotEmpty) {
      // A request with two Origin headers is malformed -- the Fetch standard
      // sends exactly one -- and it is refused rather than resolved. Matching
      // "any of them is allowed" would let an attacker append a permitted
      // origin to their own and walk straight through the check.
      if (origins.length > 1) return false;
      final normalized = origins.single.trim().toLowerCase();
      final permitted = allowedOrigins.any(
        (allowed) => allowed.trim().toLowerCase() == normalized,
      );
      if (!permitted) return false;
    }
  }
  if (allowUpgrade != null && !allowUpgrade(request)) return false;
  return true;
}

/// How long a refused request's body is drained before the peer is cut off.
///
/// Not a knob: a client that has just been told 403 has no reason to be sending
/// a slow body, so there is nothing here for an operator to tune. Generous
/// enough that an ordinary body finishes.
const Duration _refusalDrainBudget = Duration(seconds: 5);

void _refuse(HttpRequest request) {
  unawaited(_drainThenRefuse(request));
}

/// Drains [request] under a deadline, then answers 403.
///
/// Draining is necessary: dart:io tears the connection down before the status
/// is flushed if the request body is left unread, which turns a clean 403 into
/// a SocketException at the peer.
///
/// It is also the cheapest attack on this file, so the drain is BOUNDED:
/// `_refuse` is `unawaited`, so the accept loop takes the next connection at
/// once and any number of these run in parallel, counted by nothing. A socket
/// that promises a body and then sends five bytes holds one for as long as it
/// likes. Reachable exactly on the servers that turned the origin check on,
/// because `_upgradeAllowed` gates EVERY request while an upgrade-shaped one
/// carries no body to stall on.
///
/// The subscription is CANCELLED on expiry: a `.timeout()` on the drain future
/// would answer while the read loop kept running.
Future<void> _drainThenRefuse(HttpRequest request) async {
  // Object? rather than the element type, so this file needs no dart:typed_data
  // import; StreamSubscription is covariant.
  StreamSubscription<Object?>? sub;
  try {
    sub = request.listen(null);
    await sub.asFuture<void>().timeout(_refusalDrainBudget);
  } catch (_) {
    // The peer is gone, or it spent its budget. The status below is still
    // worth trying.
  } finally {
    await sub?.cancel();
  }
  try {
    request.response.statusCode = HttpStatus.forbidden;
    request.response.headers.contentType = ContentType.text;
    request.response.write('WebSocket upgrade refused');
    await request.response.close();
  } catch (_) {
    // The peer is gone, or the response was already committed. Either way there
    // is nobody left to tell, and throwing here would land in the root zone and
    // kill the isolate.
  }
}
