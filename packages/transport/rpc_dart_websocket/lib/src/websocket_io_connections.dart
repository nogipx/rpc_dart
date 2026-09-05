// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

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
Stream<WebSocketChannel> rpcWebSocketConnections(
  HttpServer server, {
  Duration? pingInterval,
  dynamic Function(List<String> protocols)? protocolSelector,
  CompressionOptions compression = CompressionOptions.compressionOff,
}) {
  return server
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
