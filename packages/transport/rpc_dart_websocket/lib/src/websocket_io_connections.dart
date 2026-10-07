// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';
import 'dart:io';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'websocket_bounded_upgrade.dart';
import 'websocket_server_policy.dart';

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
/// dart:io assembles a whole message before delivering it and has no ceiling
/// of its own, so a peer that sends fragments and never a final one is
/// buffered for as long as it writes. With compression off, each frame's
/// header is read off the socket first, and a message past the largest frame
/// the policy admits closes the connection before its payload is read.
///
/// That policy is the `RpcWebSocketServer`'s: the server hands it over when it
/// starts, and a limit raised there raises this one. [policy] overrides it for
/// a stream consumed by something else.
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
  RpcSecurityPolicy? policy,
}) {
  final ceiling = _MessageCeiling(policy);
  // Lower-cased ONCE. `_upgradeAllowed` ran `trim().toLowerCase()` over every
  // configured origin on every handshake, which allocates a string per entry per
  // connection to answer a question whose answer never changes.
  final permittedOrigins = allowedOrigins
      ?.map((origin) => origin.trim().toLowerCase())
      .toSet();

  // Filtered BEFORE the transformer rather than after: once WebSocketTransformer
  // has upgraded the request the response is already committed, and the only
  // thing left to do would be to close a socket the peer believes is open.
  //
  // Unconditional, where this used to hand `server` straight through when no gate
  // was configured. A non-upgrade request has to be caught here, and that is not
  // a gate the caller opted into — see below.
  final gated = server.where((request) {
    // The GATE comes first, and the shape check second. A forbidden origin is
    // told 403 whatever the request looked like -- that is the contract
    // `origin_guard_test` pins, and reversing the two answers a cross-origin
    // probe 400 instead, which says "wrong shape" about a request that was
    // refused on identity.
    //
    // This runs inside the accept loop's event handler, which is the ROOT
    // ZONE: anything thrown here is an unhandled async error and kills
    // the isolate -- unauthenticated, in one request. The origin read is
    // safe now, but [allowUpgrade] is USER code and cannot be, so failing
    // closed keeps a throwing predicate to a refused connection instead
    // of a dead server.
    if (permittedOrigins != null || allowUpgrade != null) {
      bool allowed;
      try {
        allowed = _upgradeAllowed(request, permittedOrigins, allowUpgrade);
      } catch (_) {
        allowed = false;
      }
      if (!allowed) {
        _answer(request, HttpStatus.forbidden, 'WebSocket upgrade refused');
        return false;
      }
    }

    // Answered HERE, because the transformer reports it as a STREAM ERROR.
    // `_upgrade` sends 400 and then completes with a `WebSocketException`, which
    // `bind` forwards to the output controller -- the server's `connections`
    // stream -- so every one reaches `onError`: an error-level record and an
    // `onConnectionError`, at whatever rate a load balancer probes. A health
    // check is not an error, and nothing downstream can tell it from one.
    //
    // A probe sends no `Origin`, so it passes the gate above and lands here.
    //
    // Guarded: dart:io reads these headers with `value()`, which THROWS on a
    // repeated one, so two Sec-WebSocket-Key headers made this predicate throw.
    // With compression on that error reached dart:io's transformer, which has
    // no error handler, and the process died.
    bool isUpgrade;
    try {
      isUpgrade = WebSocketTransformer.isUpgradeRequest(request);
    } catch (_) {
      isUpgrade = false;
    }
    if (!isUpgrade) {
      _answer(
        request,
        HttpStatus.badRequest,
        'Expected a WebSocket upgrade request',
      );
      return false;
    }
    return true;
  });

  final Stream<WebSocket> sockets = compression.enabled
      ? gated.transform(
          WebSocketTransformer(
            protocolSelector: protocolSelector,
            compression: compression,
          ),
        )
      : _upgradeEach(
          gated,
          maxMessageBytes: () => ceiling.bytes,
          protocolSelector: protocolSelector,
        );
  return _PolicyAwareConnections(
    sockets.map((socket) {
      // Set BEFORE wrapping: once inside IOWebSocketChannel the socket is no
      // longer reachable.
      socket.pingInterval = pingInterval;
      return IOWebSocketChannel(socket);
    }),
    ceiling,
  );
}

/// The frame guard's ceiling: from the policy given to the connections, or
/// else the server's, adopted when it starts.
///
/// An adopted policy only RAISES the ceiling above the default. Below it, a
/// whole message past the server's limit should still reach the multiplexer,
/// which closes with 4413 and says why; the guard can only destroy the socket,
/// which the peer reads as a retryable dropped connection.
final class _MessageCeiling {
  _MessageCeiling(RpcSecurityPolicy? own)
    : _own = own != null,
      bytes = _bytesFor(own ?? const RpcSecurityPolicy());

  final bool _own;
  int bytes;

  void adopt(RpcSecurityPolicy policy) {
    if (_own) return;
    final adopted = _bytesFor(policy);
    if (adopted > bytes) bytes = adopted;
  }

  /// The multiplexer's own reassembly cap: one WebSocket message carries
  /// exactly one channel frame.
  static int _bytesFor(RpcSecurityPolicy policy) =>
      policy.effectiveMaxBufferedBytes + RpcChannelFrame.headerSize;
}

final class _PolicyAwareConnections extends StreamView<WebSocketChannel>
    implements IRpcWebSocketServerPolicyTarget {
  _PolicyAwareConnections(super.stream, this._ceiling);

  final _MessageCeiling _ceiling;

  @override
  void adoptServerPolicy(RpcSecurityPolicy policy) => _ceiling.adopt(policy);
}

/// Upgrades every request concurrently, as [WebSocketTransformer] does, and
/// reports a failed handshake as a stream error, as it does.
Stream<WebSocket> _upgradeEach(
  Stream<HttpRequest> requests, {
  required int Function() maxMessageBytes,
  dynamic Function(List<String> protocols)? protocolSelector,
}) {
  final out = StreamController<WebSocket>();
  StreamSubscription<HttpRequest>? sub;
  out
    ..onListen = () {
      sub = requests.listen(
        (request) {
          upgradeBounded(
            request,
            maxMessageBytes: maxMessageBytes(),
            protocolSelector: protocolSelector,
          ).then(
            (socket) {
              if (out.isClosed) {
                unawaited(socket.close());
              } else {
                out.add(socket);
              }
            },
            onError: (Object error, StackTrace stackTrace) {
              if (!out.isClosed) out.addError(error, stackTrace);
            },
          );
        },
        onError: out.addError,
        onDone: out.close,
      );
    }
    ..onPause = (() => sub?.pause())
    ..onResume = (() => sub?.resume())
    ..onCancel = (() => sub?.cancel());
  return out.stream;
}

/// [permittedOrigins] is already trimmed and lower-cased by the caller.
bool _upgradeAllowed(
  HttpRequest request,
  Set<String>? permittedOrigins,
  bool Function(HttpRequest request)? allowUpgrade,
) {
  if (permittedOrigins != null) {
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
      if (!permittedOrigins.contains(normalized)) return false;
    }
  }
  if (allowUpgrade != null && !allowUpgrade(request)) return false;
  return true;
}

/// How long a rejected request's body is drained before the peer is cut off.
///
/// Not a knob: a client that has just been told 403 or 400 has no reason to be
/// sending a slow body, so there is nothing here for an operator to tune.
/// Generous enough that an ordinary body finishes.
const Duration _refusalDrainBudget = Duration(seconds: 5);

void _answer(HttpRequest request, int status, String message) {
  unawaited(_drainThenAnswer(request, status, message));
}

/// Drains [request] under a deadline, then answers [status].
///
/// Draining is necessary: dart:io tears the connection down before the status
/// is flushed if the request body is left unread, which turns a clean answer
/// into a SocketException at the peer.
///
/// It is also the cheapest attack on this file, so the drain is BOUNDED:
/// [_answer] is `unawaited`, so the accept loop takes the next connection at
/// once and any number of these run in parallel, counted by nothing. A socket
/// that promises a body and then sends five bytes holds one for as long as it
/// likes.
///
/// Reachable on EVERY server now, not only those with a gate configured: a
/// non-upgrade request is rejected here too, and a non-upgrade request is the only
/// kind that carries a body at all (dart:io hands a connection-upgrade request
/// none). The bound is what makes that acceptable, and it is the same bound.
///
/// The subscription is CANCELLED on expiry: a `.timeout()` on the drain future
/// would answer while the read loop kept running.
Future<void> _drainThenAnswer(
  HttpRequest request,
  int status,
  String message,
) async {
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
    request.response.statusCode = status;
    request.response.headers.contentType = ContentType.text;
    request.response.write(message);
    await request.response.close();
  } catch (_) {
    // The peer is gone, or the response was already committed. Either way there
    // is nobody left to tell, and throwing here would land in the root zone and
    // kill the isolate.
  }
}
