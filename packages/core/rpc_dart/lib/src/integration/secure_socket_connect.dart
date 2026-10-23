// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// A client TLS connect whose [ConnectionTask.cancel] closes the socket in
/// either stage, TCP or the TLS handshake.
///
/// `SecureSocket.startConnect` cancels only the TCP connect: once the
/// handshake owns the socket nothing can close it, so a peer that accepts TCP
/// and never answers TLS keeps it open for as long as it likes. An
/// `HttpClient` whose `connectionTimeout` fires, or that is closed with
/// `force`, cancels the task and leaves that socket behind, one per attempt.
abstract final class RpcSecureSocket {
  /// Connects to [host]:[port] over TLS, as `SecureSocket.startConnect` does.
  ///
  /// Hand it to `HttpClient.connectionFactory` for an `https` or `wss` uri
  /// with no proxy. A cancelled task completes [ConnectionTask.socket] with a
  /// [SocketException] at once and closes the socket.
  static Future<ConnectionTask<SecureSocket>> startConnect(
    Object host,
    int port, {
    SecurityContext? context,
    bool Function(X509Certificate certificate)? onBadCertificate,
    void Function(String line)? keyLog,
    List<String>? supportedProtocols,
  }) async {
    final tcp = await RawSocket.startConnect(host, port);
    final cancelled = Completer<void>();
    RawSocket? raw;

    Future<SecureSocket> open() async {
      final socket = await tcp.socket;
      raw = socket;
      if (cancelled.isCompleted) {
        unawaited(socket.close());
        throw const SocketException('Connection attempt cancelled');
      }
      final handshake = RawSecureSocket.secure(
        socket,
        host: host,
        context: context,
        onBadCertificate: onBadCertificate,
        keyLog: keyLog,
        supportedProtocols: supportedProtocols,
      );
      // Closing the socket does not end a pending handshake future, so the
      // cancel is raced; a handshake that still completes is closed.
      unawaited(
        handshake.then((secure) {
          if (cancelled.isCompleted) secure.close();
        }, onError: (Object _) {}),
      );
      final secure = await Future.any([
        handshake,
        cancelled.future.then<RawSecureSocket>(
          (_) => throw const SocketException('Connection attempt cancelled'),
        ),
      ]);
      return _RawSecureSocketAdapter(secure);
    }

    return ConnectionTask.fromSocket(open(), () {
      if (cancelled.isCompleted) return;
      cancelled.complete();
      tcp.cancel();
      final socket = raw;
      if (socket != null) unawaited(socket.close());
    });
  }
}

/// A [RawSecureSocket] as a [SecureSocket].
///
/// Reads stop while the stream is paused. [addStream] pauses its source while
/// written bytes wait for the socket, so a peer that stops reading holds the
/// writer back instead of growing the queue.
final class _RawSecureSocketAdapter extends Stream<Uint8List>
    implements SecureSocket {
  _RawSecureSocketAdapter(this._raw) {
    _raw.writeEventsEnabled = false;
    _sub = _raw.listen(_onEvent, onError: _onError, onDone: destroy);
  }

  final RawSecureSocket _raw;
  late final StreamSubscription<RawSocketEvent> _sub;

  late final StreamController<Uint8List> _in = StreamController<Uint8List>(
    onPause: () => _raw.readEventsEnabled = false,
    onResume: () => _raw.readEventsEnabled = true,
    onCancel: destroy,
  );

  final Queue<List<int>> _out = Queue<List<int>>();
  int _offset = 0;
  bool _closing = false;
  bool _destroyed = false;
  bool _streaming = false;
  final Completer<void> _done = Completer<void>();
  Completer<void>? _drained;

  @override
  Encoding encoding = utf8;

  @override
  StreamSubscription<Uint8List> listen(
    void Function(Uint8List event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => _in.stream.listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );

  void _onEvent(RawSocketEvent event) {
    switch (event) {
      case RawSocketEvent.read:
        final data = _raw.read();
        if (data != null && !_in.isClosed) _in.add(data);
      case RawSocketEvent.write:
        _flush();
      case RawSocketEvent.readClosed:
        if (!_in.isClosed) unawaited(_in.close());
      case RawSocketEvent.closed:
        destroy();
    }
  }

  void _onError(Object error, StackTrace stackTrace) {
    if (!_in.isClosed) _in.addError(error, stackTrace);
    destroy();
  }

  void _flush() {
    if (_destroyed) return;
    try {
      while (_out.isNotEmpty) {
        final chunk = _out.first;
        _offset += _raw.write(chunk, _offset);
        if (_offset < chunk.length) {
          _raw.writeEventsEnabled = true;
          return;
        }
        _out.removeFirst();
        _offset = 0;
      }
      _raw.writeEventsEnabled = false;
      _completeDrained();
      if (_closing) {
        _raw.shutdown(SocketDirection.send);
        if (!_done.isCompleted) _done.complete();
      }
    } catch (error, stackTrace) {
      _onError(error, stackTrace);
    }
  }

  void _completeDrained() {
    final drained = _drained;
    _drained = null;
    if (drained != null && !drained.isCompleted) drained.complete();
  }

  /// Completes once every queued byte is handed to the socket.
  Future<void> _whenDrained() {
    if (_out.isEmpty || _destroyed) return Future.value();
    return (_drained ??= Completer<void>()).future;
  }

  void _enqueue(List<int> data) {
    if (_destroyed || _closing || data.isEmpty) return;
    _out.add(data);
    _flush();
  }

  void _checkNotStreaming() {
    if (_streaming) {
      throw StateError('StreamSink is bound to a stream');
    }
  }

  @override
  void add(List<int> data) {
    _checkNotStreaming();
    _enqueue(data);
  }

  @override
  void addError(Object error, [StackTrace? stackTrace]) {
    _checkNotStreaming();
    _onError(error, stackTrace ?? StackTrace.current);
  }

  /// Ends the [addStream] in progress, if any; a destroyed socket takes nothing
  /// more from its source, or the source is drained into nothing for good.
  void Function()? _stopStreaming;

  @override
  Future<void> addStream(Stream<List<int>> stream) {
    _checkNotStreaming();
    if (_destroyed) return Future.value();
    _streaming = true;
    final finished = Completer<void>();
    late final StreamSubscription<List<int>> sub;
    void finish([Object? error, StackTrace? stackTrace]) {
      _streaming = false;
      _stopStreaming = null;
      if (finished.isCompleted) return;
      if (error == null) {
        finished.complete();
      } else {
        finished.completeError(error, stackTrace);
      }
    }

    _stopStreaming = () {
      unawaited(sub.cancel());
      finish();
    };
    sub = stream.listen(
      (data) {
        _enqueue(data);
        if (_out.isNotEmpty && !_destroyed) {
          sub.pause(_whenDrained());
        }
      },
      onError: finish,
      onDone: finish,
      cancelOnError: true,
    );
    return finished.future;
  }

  @override
  void write(Object? object) {
    final string = '$object';
    if (string.isEmpty) return;
    add(encoding.encode(string));
  }

  @override
  void writeAll(Iterable<Object?> objects, [String separator = '']) =>
      write(objects.join(separator));

  @override
  void writeCharCode(int charCode) => write(String.fromCharCode(charCode));

  @override
  void writeln([Object? object = '']) => write('$object\n');

  @override
  Future<void> flush() {
    _checkNotStreaming();
    return _whenDrained();
  }

  @override
  Future<void> close() {
    if (!_closing && !_destroyed) {
      _closing = true;
      _flush();
    }
    return done;
  }

  @override
  Future<void> get done => _done.future;

  @override
  void destroy() {
    if (_destroyed) return;
    _destroyed = true;
    _out.clear();
    _stopStreaming?.call();
    _completeDrained();
    unawaited(_sub.cancel());
    try {
      _raw.close();
    } catch (_) {}
    if (!_in.isClosed) unawaited(_in.close());
    if (!_done.isCompleted) _done.complete();
  }

  @override
  InternetAddress get address => _raw.address;

  @override
  InternetAddress get remoteAddress => _raw.remoteAddress;

  @override
  int get port => _raw.port;

  @override
  int get remotePort => _raw.remotePort;

  @override
  bool setOption(SocketOption option, bool enabled) =>
      _raw.setOption(option, enabled);

  @override
  Uint8List getRawOption(RawSocketOption option) => _raw.getRawOption(option);

  @override
  void setRawOption(RawSocketOption option) => _raw.setRawOption(option);

  @override
  X509Certificate? get peerCertificate => _raw.peerCertificate;

  @override
  String? get selectedProtocol => _raw.selectedProtocol;

  @override
  // ignore: deprecated_member_use
  void renegotiate({
    bool useSessionCache = true,
    bool requestClientCertificate = false,
    bool requireClientCertificate = false,
  }) => throw UnsupportedError('TLS renegotiation is not supported');
}
