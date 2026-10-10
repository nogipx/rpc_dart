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

/// A [ServerSocket] that reports when each accepted connection ends.
///
/// HTTP/1.1 has no cancel frame: a caller cancels by closing its connection.
/// dart:io sees the close, and neither it nor shelf tells the handler.
final class PeerWatchingServerSocket extends Stream<Socket>
    implements ServerSocket {
  PeerWatchingServerSocket(this._server);

  final ServerSocket _server;
  final Map<String, Completer<void>> _gone = {};

  /// Completes when the connection [info] describes has ended; null for one
  /// this socket did not accept.
  Future<void>? peerGone(HttpConnectionInfo info) =>
      _gone[_key(info.remoteAddress, info.remotePort)]?.future;

  static String _key(InternetAddress address, int port) =>
      '${address.address}:$port';

  Socket _watch(Socket socket) {
    final key = _key(socket.remoteAddress, socket.remotePort);
    final gone = Completer<void>();
    _gone[key] = gone;
    return _WatchedSocket(socket, () {
      _gone.remove(key);
      if (!gone.isCompleted) gone.complete();
    });
  }

  @override
  StreamSubscription<Socket> listen(
    void Function(Socket event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => _server
      .map<Socket>(_watch)
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

/// A [Socket] that calls [_ended] when its inbound stream ends or fails.
final class _WatchedSocket extends Stream<Uint8List> implements Socket {
  _WatchedSocket(this._socket, this._ended);

  final Socket _socket;
  final void Function() _ended;

  @override
  StreamSubscription<Uint8List> listen(
    void Function(Uint8List event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => _socket.listen(
    onData,
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
