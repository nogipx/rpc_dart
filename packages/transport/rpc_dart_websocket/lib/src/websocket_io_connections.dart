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
/// negotiation.
///
/// [compression] controls permessage-deflate. It defaults to
/// [CompressionOptions.compressionOff] — NOT dart:io's default, which is ON —
/// because a server accepts connections from unauthenticated peers and
/// permessage-deflate is an unbounded decompression bomb on that side. dart:io
/// inflates each incoming message with `RawZLibFilter` and NO output limit
/// (`processIncomingMessage` in `websocket_impl.dart` just accumulates into a
/// `BytesBuilder`), and it does so BEFORE the message reaches rpc_dart, so the
/// frame layer's [RpcSecurityPolicy.maxMessageLengthBytes] cannot bound it —
/// the memory is already allocated by the time the cap would fire. Same
/// "limit fires too late" class as the HTTP/1.1 body and the frame buffer.
///
/// Measured against this server with compression ON, one raw client:
///
///     a 256 MiB payload of zeros — a few hundred KiB on the wire once deflated
///     — inflated to a 383.8 MiB RSS peak, against a 16 MiB message limit. The
///     amplification (~1000:1 for repetitive data) is what makes it a cheap,
///     unauthenticated DoS: a few MiB uploaded becomes GiB of server RAM.
///
/// dart:io exposes no way to bound the inflated size, so the only lever rpc_dart
/// has is whether to negotiate the extension at all; the safe server default is
/// therefore OFF. Turn it on ONLY between peers you control, where the bandwidth
/// saving is worth it and neither side is hostile:
///
/// ```dart
/// rpcWebSocketConnections(http,
///     compression: CompressionOptions.compressionDefault);
/// ```
///
/// This does not stop a peer from sending a large UNCOMPRESSED message, which
/// dart:io also buffers whole before delivery — that costs the attacker
/// bandwidth proportional to the damage and has no dart:io-level bound; put a
/// reverse proxy or OS-level limit in front if that matters.
///
/// [allowedOrigins] refuses cross-origin handshakes, and is the reason a server
/// needs this seam a second time.
///
/// WebSocket is NOT subject to the same-origin policy. A browser will open a
/// socket from any page to any server and attach the user's ambient
/// credentials — cookies, HTTP auth — exactly as it would for an image tag. The
/// only defence at the protocol level is for the server to check the `Origin`
/// header during the handshake, which is why dart:io exposes it on the
/// [HttpRequest]. Until now nothing here could: `server.transform(...)` consumes
/// the request stream whole, so the application never saw a request and had no
/// place to refuse one. Measured against this server before the check existed:
///
///     Origin: https://evil.example  ->  SERVED "the users private data"
///
/// The HTTP/1.1 transport has shipped a full CORS policy since round 44; this
/// one had no equivalent, so an operator who had locked down one transport was
/// wide open on the other.
///
/// Values are compared case-insensitively against the whole origin
/// (`scheme://host[:port]`, no trailing slash), e.g.
/// `{'https://app.example.com'}`.
///
/// A request with NO `Origin` header is ALLOWED even when this is set, and that
/// is deliberate rather than an oversight: `Origin` is attached by browsers,
/// and every non-browser client — Dart, Go, grpcurl, a mobile app — sends none.
/// Refusing those would break the majority of rpc_dart's clients while stopping
/// nobody, because the attack this defends against is a browser page riding
/// credentials it cannot read. An attacker calling the server directly has no
/// victim's cookies to ride, and is a job for authentication, not for this. The
/// literal origin `null`, which sandboxed iframes and `file://` pages send, is
/// treated as a value like any other: allowed only if you list it. A request
/// carrying MORE THAN ONE `Origin` header is refused outright — the Fetch
/// standard sends exactly one, and accepting "any of them is allowed" would let
/// a peer append a permitted origin to its own.
///
/// [allowUpgrade] is the general form, run after [allowedOrigins] and only if
/// that passed — both must accept. It sees the whole [HttpRequest], so it can
/// check a token in the query string, a header, or the path. It is synchronous
/// on purpose: it runs in the accept path, where an await would serialize every
/// handshake behind the slowest one. Do asynchronous authentication after the
/// connection is up, where a slow answer costs one peer rather than all of them.
///
/// If it throws, the connection is refused and the server carries on. That is
/// deliberate rather than lenient: the accept loop runs in the ROOT ZONE, so an
/// escaping exception is an unhandled async error and kills the isolate — one
/// bad predicate would take the whole server down instead of one connection.
///
/// A refused request is answered `403` and never upgraded, so the peer gets a
/// real HTTP error rather than a socket that closes for no stated reason.
///
/// ```dart
/// final http = await HttpServer.bind(host, port);
/// final server = RpcWebSocketServer(
///   connections: rpcWebSocketConnections(
///     http,
///     pingInterval: const Duration(seconds: 30),
///     allowedOrigins: {'https://app.example.com'},
///   ),
///   onEndpointCreated: ...,
/// );
/// ```
Stream<WebSocketChannel> rpcWebSocketConnections(
  HttpServer server, {
  Duration? pingInterval,
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
          // The guard runs inside the accept loop's event handler, which is
          // the ROOT ZONE: anything it throws is an unhandled async error and
          // kills the isolate. That is not hypothetical -- reading the origin
          // with `headers.value()` threw on a request carrying two Origin
          // headers, so six lines of raw HTTP took the whole server process
          // down, unauthenticated, in one request.
          //
          // The read is safe now, but [allowUpgrade] is USER code and cannot
          // be. Failing closed here keeps a throwing predicate to a refused
          // connection instead of a dead server.
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

void _refuse(HttpRequest request) {
  // Drained before answering: dart:io tears the connection down before the
  // status is flushed if the request body is left unread, which turns a clean
  // 403 into a SocketException at the peer. The HTTP/1.1 transport's _reject
  // learned this the same way.
  unawaited(
    request
        .drain<void>()
        .then((_) {
          request.response.statusCode = HttpStatus.forbidden;
          request.response.headers.contentType = ContentType.text;
          request.response.write('WebSocket upgrade refused');
          return request.response.close();
        })
        .catchError((Object _) {
          // The peer is gone, or the response was already committed. Either way
          // there is nobody left to tell, and throwing here would land in the
          // root zone and kill the isolate.
        }),
  );
}
