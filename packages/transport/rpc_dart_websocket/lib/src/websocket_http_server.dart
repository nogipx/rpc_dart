// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:rpc_dart/rpc_dart.dart';

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
  final bounded = _HeaderBoundedServerSocket(
    socket,
    maxHeaderBytes:
        maxHeaderBytes ??
        4 *
            (policy.maxMethodPathLength +
                policy.maxMetadataBytes +
                4 * policy.maxHeaders +
                1024),
    headerTimeout: headerTimeout,
    maxConnections: maxConnections,
  );
  return _BoundedHttpServer(HttpServer.listenOn(bounded), bounded);
}

/// An [HttpServer] over a [_HeaderBoundedServerSocket] whose [close] releases
/// the socket too: `HttpServer.listenOn` leaves a socket it was given open.
final class _BoundedHttpServer extends Stream<HttpRequest>
    implements HttpServer {
  _BoundedHttpServer(this._server, this._socket);

  final HttpServer _server;
  final _HeaderBoundedServerSocket _socket;

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

/// A [ServerSocket] that bounds each accepted connection's first header
/// block, and the number of open connections.
///
/// Only the first block: a connection here carries one upgrade request, and
/// `rpcWebSocketConnections` closes any connection it refuses, so after the
/// block ends the bytes are WebSocket frames, bounded by the frame guard.
final class _HeaderBoundedServerSocket extends Stream<Socket>
    implements ServerSocket {
  _HeaderBoundedServerSocket(
    this._server, {
    required this.maxHeaderBytes,
    required this.headerTimeout,
    required this.maxConnections,
  });

  final ServerSocket _server;
  final int? maxHeaderBytes;
  final Duration? headerTimeout;
  final int? maxConnections;
  int _open = 0;

  Iterable<Socket> _accept(Socket socket) {
    final cap = maxConnections;
    if (cap != null && _open >= cap) {
      socket.destroy();
      return const [];
    }
    _open++;
    return [
      _HeaderBoundedSocket(
        socket,
        maxHeaderBytes: maxHeaderBytes,
        headerTimeout: headerTimeout,
        onEnded: () => _open--,
      ),
    ];
  }

  @override
  StreamSubscription<Socket> listen(
    void Function(Socket event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => _server
      .expand<Socket>(_accept)
      .listen(
        onData,
        onError: onError,
        onDone: onDone,
        cancelOnError: cancelOnError,
      );

  @override
  int get port => _server.port;

  @override
  InternetAddress get address => _server.address;

  @override
  Future<ServerSocket> close() async {
    await _server.close();
    return this;
  }
}

/// A [Socket] that closes itself when its first header block is too long or
/// too slow.
final class _HeaderBoundedSocket extends Stream<Uint8List> implements Socket {
  _HeaderBoundedSocket(
    this._socket, {
    required int? maxHeaderBytes,
    required Duration? headerTimeout,
    required void Function() onEnded,
  }) : _maxHeaderBytes = maxHeaderBytes,
       _onEnded = onEnded {
    if (headerTimeout != null) {
      _deadline = Timer(headerTimeout, _socket.destroy);
    }
    // The upgrade replaces the handlers [listen] installed; without this an
    // upgraded connection keeps its maxConnections slot after it ends.
    _socket.done.then((_) => _end(), onError: (Object _) => _end());
  }

  final Socket _socket;
  final int? _maxHeaderBytes;
  final void Function() _onEnded;
  Timer? _deadline;
  bool _inHeaders = true;
  bool _ended = false;
  int _headerBytes = 0;

  /// How much of `\r\n\r\n` the bytes so far end with.
  int _matched = 0;

  void _end() {
    if (_ended) return;
    _ended = true;
    _deadline?.cancel();
    _onEnded();
  }

  /// Counts [chunk] against the header block; false once the block is over
  /// [_maxHeaderBytes] and the connection has been closed.
  bool _admit(Uint8List chunk) {
    if (!_inHeaders) return true;
    for (var i = 0; i < chunk.length; i++) {
      final b = chunk[i];
      _matched = b == (_matched.isEven ? 13 : 10)
          ? _matched + 1
          : (b == 13 ? 1 : 0);
      if (_matched == 4) {
        _headerBytes += i + 1;
        _inHeaders = false;
        _deadline?.cancel();
        return _withinCap();
      }
    }
    _headerBytes += chunk.length;
    return _withinCap();
  }

  bool _withinCap() {
    final cap = _maxHeaderBytes;
    if (cap == null || _headerBytes <= cap) return true;
    _socket.destroy();
    return false;
  }

  @override
  StreamSubscription<Uint8List> listen(
    void Function(Uint8List event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => _socket.listen(
    (chunk) {
      if (_admit(chunk)) onData?.call(chunk);
    },
    onError: (Object e, StackTrace st) {
      _end();
      switch (onError) {
        case final void Function(Object, StackTrace) f:
          f(e, st);
        case final void Function(Object) f:
          f(e);
        default:
          Zone.current.handleUncaughtError(e, st);
      }
    },
    onDone: () {
      _end();
      onDone?.call();
    },
    cancelOnError: cancelOnError,
  );

  @override
  int get port => _socket.port;
  @override
  int get remotePort => _socket.remotePort;
  @override
  InternetAddress get address => _socket.address;
  @override
  InternetAddress get remoteAddress => _socket.remoteAddress;
  @override
  Encoding get encoding => _socket.encoding;
  @override
  set encoding(Encoding value) => _socket.encoding = value;
  @override
  Future<void> get done => _socket.done;
  @override
  void add(List<int> data) => _socket.add(data);
  @override
  void addError(Object error, [StackTrace? stackTrace]) =>
      _socket.addError(error, stackTrace);
  @override
  Future<void> addStream(Stream<List<int>> stream) => _socket.addStream(stream);
  @override
  Future<void> close() => _socket.close();
  @override
  void destroy() {
    _end();
    _socket.destroy();
  }

  @override
  Future<void> flush() => _socket.flush();
  @override
  bool setOption(SocketOption option, bool enabled) =>
      _socket.setOption(option, enabled);
  @override
  Uint8List getRawOption(RawSocketOption option) =>
      _socket.getRawOption(option);
  @override
  void setRawOption(RawSocketOption option) => _socket.setRawOption(option);
  @override
  void write(Object? object) => _socket.write(object);
  @override
  void writeAll(Iterable<Object?> objects, [String separator = '']) =>
      _socket.writeAll(objects, separator);
  @override
  void writeCharCode(int charCode) => _socket.writeCharCode(charCode);
  @override
  void writeln([Object? object = '']) => _socket.writeln(object);
}
