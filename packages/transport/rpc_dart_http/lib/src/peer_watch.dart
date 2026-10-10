// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// `Request.context` key under which [RpcHttpServer] gives each request a
/// `Future<void>` that completes when the client's connection has ended.
///
/// Absent when the responder transport is mounted on any other shelf server;
/// there a caller's cancel does not reach the handler.
const String kRpcHttpPeerGoneKey = 'rpc_dart_http.peer_gone';

/// A [ServerSocket] that watches every connection it accepts for the
/// [HttpServer] it feeds.
///
/// - It reports when a connection ends ([peerGone]). HTTP/1.1 has no cancel
///   frame: a caller cancels by closing its connection, and neither dart:io
///   nor shelf tells the handler.
/// - It bounds a request's header block in bytes ([maxHeaderBytes]) and in
///   time ([headerTimeout]), and the number of open connections
///   ([maxConnections]). dart:io holds an unfinished header block below every
///   rpc_dart limit, up to about 3 MiB per connection, for as long as the
///   client keeps it open.
final class PeerWatchingServerSocket extends Stream<Socket>
    implements ServerSocket {
  PeerWatchingServerSocket(
    this._server, {
    this.maxHeaderBytes,
    this.headerTimeout,
    this.maxConnections,
  });

  final ServerSocket _server;

  /// Bytes a request may send before its header block ends; past it the
  /// connection is closed. Null for no bound.
  final int? maxHeaderBytes;

  /// How long a request's header block may take, from the connection's
  /// accept or the first byte of a later request; past it the connection is
  /// closed. Null for no bound.
  final Duration? headerTimeout;

  /// Open connections at most; one more is closed as it is accepted. Null for
  /// no bound.
  final int? maxConnections;

  final Map<String, _WatchedSocket> _open = {};

  /// Completes when the connection [info] describes has ended; null for one
  /// this socket did not accept.
  Future<void>? peerGone(HttpConnectionInfo info) =>
      _open[_key(info.remoteAddress, info.remotePort)]?.gone;

  /// The response to the connection's current request has been written: the
  /// next bytes start a new header block.
  void responseWritten(HttpConnectionInfo info) =>
      _open[_key(info.remoteAddress, info.remotePort)]?._expectHeaders();

  static String _key(InternetAddress address, int port) =>
      '${address.address}:$port';

  Iterable<Socket> _accept(Socket socket) {
    final cap = maxConnections;
    if (cap != null && _open.length >= cap) {
      socket.destroy();
      return const [];
    }
    final key = _key(socket.remoteAddress, socket.remotePort);
    final watched = _WatchedSocket(
      socket,
      maxHeaderBytes: maxHeaderBytes,
      headerTimeout: headerTimeout,
      onEnded: () => _open.remove(key),
    );
    _open[key] = watched;
    return [watched];
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

/// A [Socket] that reports its end and bounds each request's header block.
final class _WatchedSocket extends Stream<Uint8List> implements Socket {
  _WatchedSocket(
    this._socket, {
    required int? maxHeaderBytes,
    required Duration? headerTimeout,
    required void Function() onEnded,
  }) : _maxHeaderBytes = maxHeaderBytes,
       _headerTimeout = headerTimeout,
       _onEnded = onEnded {
    // The first request is due from the accept on.
    _armDeadline();
  }

  final Socket _socket;
  final int? _maxHeaderBytes;
  final Duration? _headerTimeout;
  final void Function() _onEnded;
  final Completer<void> _gone = Completer<void>();

  /// Whether the bytes arriving belong to a header block.
  bool _inHeaders = true;
  int _headerBytes = 0;

  /// How much of `\r\n\r\n` the bytes so far end with.
  int _matched = 0;
  Timer? _deadline;

  Future<void> get gone => _gone.future;

  void _ended() {
    _deadline?.cancel();
    _onEnded();
    if (!_gone.isCompleted) _gone.complete();
  }

  void _armDeadline() {
    final limit = _headerTimeout;
    if (limit == null) return;
    _deadline?.cancel();
    _deadline = Timer(limit, _socket.destroy);
  }

  /// Called once a response is written; a keep-alive connection idles until
  /// its next request, which dart:io's own `idleTimeout` bounds.
  void _expectHeaders() {
    _inHeaders = true;
    _headerBytes = 0;
    _matched = 0;
  }

  /// Counts [chunk] against the current header block; false once the block
  /// is over [_maxHeaderBytes] and the connection has been closed.
  bool _admit(Uint8List chunk) {
    if (!_inHeaders) return true;
    if (_headerBytes == 0 && _matched == 0 && _deadline?.isActive != true) {
      // A later request on a kept-alive connection: due from its first byte.
      _armDeadline();
    }
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
      _ended();
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
      _ended();
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
    _ended();
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
