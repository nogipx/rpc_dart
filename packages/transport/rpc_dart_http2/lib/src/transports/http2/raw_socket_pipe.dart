// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';
import 'dart:collection';

import 'package:universal_io/io.dart';

/// A [RawSocket] as the byte stream and sink HTTP/2 reads and writes.
///
/// The proxy path works on a [RawSocket] because it is the only kind that stays
/// closable through a TLS handshake: once `SecureSocket.secure` owns a
/// [Socket], destroying the original no longer closes it, so a handshake that
/// times out leaves its socket open. `RawSecureSocket.secure` leaves the
/// [RawSocket] in the caller's hands, and this turns the result into what
/// `ClientTransportConnection.viaStreams` takes.
///
/// Reads stop while [incoming] is paused. Writes queue without bound, as a
/// [Socket]'s do; HTTP/2's own windows bound what is written.
final class RawSocketPipe implements StreamSink<List<int>> {
  /// Wraps [raw], taking over [subscription] if the caller already listens.
  RawSocketPipe(this._raw, {StreamSubscription<RawSocketEvent>? subscription}) {
    _raw.writeEventsEnabled = false;
    final sub = subscription ?? _raw.listen(null);
    sub
      ..onData(_onEvent)
      ..onError(_onError)
      ..onDone(_onDone);
    _sub = sub;
    _raw.readEventsEnabled = true;
  }

  final RawSocket _raw;
  late final StreamSubscription<RawSocketEvent> _sub;

  late final StreamController<List<int>> _in = StreamController<List<int>>(
    onPause: () => _raw.readEventsEnabled = false,
    onResume: () => _raw.readEventsEnabled = true,
  );

  final Queue<List<int>> _out = Queue<List<int>>();
  int _offset = 0;
  bool _closing = false;
  bool _destroyed = false;
  final Completer<void> _done = Completer<void>();

  /// Bytes read from the socket.
  Stream<List<int>> get incoming => _in.stream;

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

  void _onDone() => destroy();

  @override
  void add(List<int> data) {
    if (_destroyed || _closing) return;
    _out.add(data);
    _flush();
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
      if (_closing) {
        _raw.shutdown(SocketDirection.send);
        if (!_done.isCompleted) _done.complete();
      }
    } catch (error, stackTrace) {
      _onError(error, stackTrace);
    }
  }

  @override
  void addError(Object error, [StackTrace? stackTrace]) {}

  @override
  Future<void> addStream(Stream<List<int>> stream) => stream.forEach(add);

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

  /// Closes the socket in both directions and drops anything unwritten.
  void destroy() {
    if (_destroyed) return;
    _destroyed = true;
    _out.clear();
    unawaited(_sub.cancel());
    try {
      _raw.close();
    } catch (_) {}
    if (!_in.isClosed) unawaited(_in.close());
    if (!_done.isCompleted) _done.complete();
  }
}
