// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';
import 'dart:io';

import 'package:rpc_dart/transport_io.dart';

/// Binds an [HttpServer] for `rpcWebSocketConnections` that bounds what a
/// connection may send before its upgrade request ends.
///
/// dart:io holds an unfinished request header block below every rpc_dart
/// limit, for as long as the client keeps the connection open. A server bound
/// here closes a connection whose header block passes [maxHeaderBytes] (by
/// default four times what [policy] admits as one request's head) or takes
/// longer than [headerTimeout] from the accept, and refuses connections past
/// [maxConnections] (off by default: while attackers fill it, honest clients
/// are refused too). The same bounds `RpcHttpServer` puts on its own socket.
///
/// Only the first header block is bounded: a connection here carries one
/// upgrade request, and `rpcWebSocketConnections` closes any connection it
/// refuses, so after the block ends the bytes are WebSocket frames, bounded by
/// the frame guard.
///
/// Close the returned server as any other: closing it releases the port.
///
/// ```dart
/// final http = await bindRpcWebSocketHttpServer(InternetAddress.anyIPv4, 8080);
/// final server = RpcWebSocketServer(
///   connections: rpcWebSocketConnections(http),
///   mode: RpcResponderMode.contracts([...]),
/// );
/// ```
Future<HttpServer> bindRpcWebSocketHttpServer(
  Object address,
  int port, {
  RpcSecurityPolicy policy = const RpcSecurityPolicy(),
  int? maxHeaderBytes,
  Duration? headerTimeout = const Duration(seconds: 60),
  int? maxConnections,
  int backlog = 0,
  bool v6Only = false,
  bool shared = false,
}) async {
  final socket = await ServerSocket.bind(
    address,
    port,
    backlog: backlog,
    v6Only: v6Only,
    shared: shared,
  );
  final bounded = RpcHeaderBoundedServerSocket(
    socket,
    maxHeaderBytes:
        maxHeaderBytes ??
        RpcHeaderBoundedServerSocket.defaultMaxHeaderBytes(policy),
    headerTimeout: headerTimeout,
    maxConnections: maxConnections,
  );
  return _BoundedHttpServer(HttpServer.listenOn(bounded), bounded);
}

/// An [HttpServer] over an [RpcHeaderBoundedServerSocket] whose [close]
/// releases the socket too: `HttpServer.listenOn` leaves a socket it was given
/// open.
final class _BoundedHttpServer extends Stream<HttpRequest>
    implements HttpServer {
  _BoundedHttpServer(this._server, this._socket);

  final HttpServer _server;
  final RpcHeaderBoundedServerSocket _socket;

  @override
  StreamSubscription<HttpRequest> listen(
    void Function(HttpRequest event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => _server.listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );

  @override
  Future<void> close({bool force = false}) async {
    await _server.close(force: force);
    await _socket.close();
  }

  @override
  InternetAddress get address => _server.address;
  @override
  int get port => _server.port;
  @override
  bool get autoCompress => _server.autoCompress;
  @override
  set autoCompress(bool value) => _server.autoCompress = value;
  @override
  HttpHeaders get defaultResponseHeaders => _server.defaultResponseHeaders;
  @override
  Duration? get idleTimeout => _server.idleTimeout;
  @override
  set idleTimeout(Duration? value) => _server.idleTimeout = value;
  @override
  String? get serverHeader => _server.serverHeader;
  @override
  set serverHeader(String? value) => _server.serverHeader = value;
  @override
  set sessionTimeout(int timeout) => _server.sessionTimeout = timeout;
  @override
  HttpConnectionsInfo connectionsInfo() => _server.connectionsInfo();
}
