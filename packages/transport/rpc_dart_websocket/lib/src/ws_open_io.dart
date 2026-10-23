// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';
import 'dart:io';

import 'package:rpc_dart/transport_io.dart' show RpcSecureSocket;
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'websocket_bounded_upgrade.dart';

/// Whether THIS platform's `openWebSocket` actually applies `pingInterval`.
///
/// True here: dart:io owns the ping and closes the socket itself when no pong
/// returns. The web implementation cannot, and says so with `false`, which is
/// what `RpcWebSocketCallerTransport` reads to decide whether it has to run an
/// application-level heartbeat instead.
const bool platformHonoursPingInterval = true;

/// A connection factory for an `HttpClient` that connects only to [target]'s
/// origin: a redirect elsewhere fails the connect instead of carrying the
/// upgrade request's headers there.
///
/// With a factory set, `HttpClient` leaves TLS to it for a direct connection
/// and still tunnels through a proxy itself. TLS goes through
/// [RpcSecureSocket]: with dart:io's own connect, a timeout or a cancel during
/// the handshake left the socket open, one per reconnect attempt.
Future<ConnectionTask<Socket>> Function(Uri, String?, int?) _sameOriginOnly(
  Uri target,
) {
  final scheme = target.isScheme('wss') ? 'https' : 'http';
  final host = target.host;
  final port = target.port;
  return (uri, proxyHost, proxyPort) {
    if (uri.scheme != scheme || uri.host != host || uri.port != port) {
      return Future.error(
        const WebSocketException(
          'WebSocket upgrade redirected to another origin; not followed',
        ),
      );
    }
    if (proxyHost != null && proxyPort != null) {
      return Socket.startConnect(proxyHost, proxyPort);
    }
    return uri.isScheme('https')
        ? RpcSecureSocket.startConnect(host, port)
        : Socket.startConnect(host, port);
  };
}

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
/// [headers] go on the upgrade REQUEST, which is the only place a websocket
/// client can authenticate: there is no second round trip to attach a token to.
///
/// [connectTimeout] bounds the whole open — TCP connect, HTTP upgrade and
/// `ready` — and ABANDONS it, rather than merely stopping the wait. Without it a
/// peer that accepts the connection and never answers holds the caller until the
/// OS gives up, which on a black hole (a firewall that DROPs, a balancer with no
/// backend) is minutes.
///
/// Setting it gives the attempt a private [HttpClient], because that is the only
/// thing there is to cancel: `WebSocket.connect` otherwise uses a process-wide
/// one, and a `Future.timeout` over it leaves the connect running with its
/// descriptor held.
///
/// The raw dart:io WebSocket is opened here rather than through
/// [IOWebSocketChannel.connect], which passes no compression argument and so
/// always takes dart:io's default (ON).
///
/// [maxMessageBytes] bounds each inbound message, checked from frame headers
/// before dart:io buffers the payload; past it the socket is destroyed. dart:io
/// alone assembles a message with no ceiling, so a server that never sends a
/// final fragment grows the client for as long as it writes. Not applied with
/// compression on, where dart:io's own handshake is used.
///
/// [cancelled] abandons the open the way [connectTimeout] does, when it
/// completes first: the attempt's own client is force-closed, which takes the
/// pending connect and its descriptor with it.
Future<WebSocketChannel> openWebSocket(
  Uri uri, {
  Iterable<String>? protocols,
  Duration? pingInterval,
  bool enableCompression = false,
  Map<String, Object>? headers,
  Duration? connectTimeout,
  int? maxMessageBytes,
  Future<void>? cancelled,
}) async {
  Future<WebSocketChannel> open(HttpClient? client) async {
    final ceiling = enableCompression ? null : maxMessageBytes;
    final WebSocket webSocket;
    if (ceiling != null) {
      final own = client ?? HttpClient();
      own.connectionFactory = _sameOriginOnly(uri);
      try {
        webSocket = await connectBounded(
          uri,
          client: own,
          maxMessageBytes: ceiling,
          protocols: protocols,
          headers: headers,
        );
      } finally {
        // The upgraded socket is detached, so this closes only what is idle.
        if (client == null) own.close();
      }
    } else {
      // dart:io's handshake follows a redirect with every header the caller
      // set, and offers no setting against it; its client is given a
      // connection factory that refuses any other origin instead.
      final own = client ?? HttpClient();
      own.connectionFactory = _sameOriginOnly(uri);
      try {
        webSocket = await WebSocket.connect(
          uri.toString(),
          protocols: protocols,
          headers: headers,
          compression: enableCompression
              ? CompressionOptions.compressionDefault
              : CompressionOptions.compressionOff,
          customClient: own,
        );
      } finally {
        if (client == null) own.close();
      }
    }
    webSocket.pingInterval = pingInterval;
    final channel = IOWebSocketChannel(webSocket);
    await channel.ready;
    return channel;
  }

  // Null hands `WebSocket.connect` its own process-wide client, which is right:
  // with no timeout and no cancel there is nothing to abandon and nothing to own.
  if (connectTimeout == null && cancelled == null) return open(null);

  // Its OWN client, so a timeout or a cancel has something to CANCEL. Without
  // one, `WebSocket.connect` uses a static shared client and the only thing
  // either can do is stop waiting -- see below.
  final client = HttpClient();
  if (connectTimeout != null) client.connectionTimeout = connectTimeout;

  // `Future.timeout` abandons the AWAIT, not the WORK, and that cuts two ways.
  //
  // A socket that arrives LATE is a live socket nobody holds, which core learned
  // on RpcClientConnection's connectTimeout; the late arrival is closed below
  // rather than dropped.
  //
  // A socket that never arrives is worse, because nothing marks it as finished:
  // against a black hole the OS retries the SYN for over a minute, holding one
  // descriptor per abandoned attempt. A reconnect loop against an unreachable
  // host accumulates them.
  //
  // OWNING the client is what releases it — closing it takes the pending connect
  // with it, where a `Future.timeout` over the shared client can only stop
  // waiting. `connectionTimeout` states the same bound inside the client; the
  // two cannot be told apart by measurement here, since both bounds are this
  // same duration.
  var abandoned = false;
  final opening = open(client);
  unawaited(
    opening
        .then((channel) {
          if (abandoned) unawaited(channel.sink.close().catchError((_) {}));
        })
        .catchError((Object _) {}),
  );
  try {
    var waiting = opening;
    if (connectTimeout != null) {
      waiting = waiting.timeout(
        connectTimeout,
        onTimeout: () {
          abandoned = true;
          throw TimeoutException(
            'WebSocket connect to $uri timed out',
            connectTimeout,
          );
        },
      );
    }
    var opened = false;
    if (cancelled != null) {
      waiting = Future.any([
        waiting,
        cancelled.then<WebSocketChannel>((_) {
          // A cancel after the open is the caller's business, not this one's.
          if (!opened) abandoned = true;
          throw StateError('WebSocket connect cancelled');
        }),
      ]);
    }
    final channel = await waiting;
    opened = true;
    // Not forced: this closes IDLE connections, and an upgraded WebSocket has
    // been detached from the client by `WebSocket.connect`, so the live socket is
    // unaffected. Skipping it would leak the client object itself, one per call.
    client.close();
    return channel;
  } catch (_) {
    client.close(force: true);
    rethrow;
  }
}
