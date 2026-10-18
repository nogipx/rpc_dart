// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';
import 'dart:io';

import 'package:rpc_dart/transport.dart';

/// [IRpcChannel] over a `dart:io` [Socket]: the socket's byte stream as a raw
/// pipe, opened by a preface in each direction.
///
/// **The preface.** Each side writes [preface] as its first bytes and reads
/// the peer's before anything else. A bare socket otherwise says nothing about
/// who answered it: a process that accepts and never speaks, or one speaking
/// another protocol on the same path, looks exactly like an idle rpc_dart
/// server. [ready] completes once the peer's preface has arrived intact, and
/// fails when it is wrong, when the connection ends first, or when
/// [prefaceTimeout] passes. Both ends must therefore be an [RpcSocketChannel].
///
/// A socket has no message boundaries, and none are needed:
/// `RpcFrameMultiplexedChannel`, which [RpcChannelTransport.fromChannel] puts
/// on top, reassembles frames from arbitrary chunks. Bytes the peer sends
/// right behind its preface are kept and delivered after it.
///
/// **Writes never wait; reads do.** [send] queues and returns. Flow control
/// bounds DATA, but not what a call is answered with outside it (metadata,
/// trailers), so a peer that never reads and keeps starting calls would grow
/// the queue without end. With [maxWriteBacklogBytes] set, a queue past it
/// stops this side reading the peer until the queue has halved.
///
/// **A closing peer cannot say why.** A raw socket has no close code, so a
/// connection closed for a protocol violation reaches the peer as an ordinary
/// end of stream, which its caller reports as UNAVAILABLE.
class RpcSocketChannel implements IRpcChannel {
  /// Wraps [socket], which this channel then owns: [close] closes it. The
  /// preface is written at once.
  ///
  /// [prefaceTimeout] bounds the wait for the peer's preface; past it the
  /// channel closes and [ready] fails with UNAVAILABLE. Null waits for ever.
  ///
  /// [closeTimeout] bounds the orderly close. Closing flushes what is still
  /// buffered and then sends FIN, and a peer that stopped reading can hold
  /// that flush for ever, so past the bound the socket is destroyed.
  ///
  /// [maxWriteBacklogBytes] is the unsent bytes past which reading pauses.
  /// Null never pauses. A server sets it and a client does not: if both ends
  /// paused, each would wait for the other to read.
  RpcSocketChannel(
    Socket socket, {
    Duration? prefaceTimeout = const Duration(seconds: 10),
    Duration closeTimeout = const Duration(seconds: 5),
    this.maxWriteBacklogBytes,
  }) : _socket = socket,
       _closeTimeout = closeTimeout,
       _backlog = RpcWriteBacklog(maxUnsentBytes: maxWriteBacklogBytes),
       peer = _describe(socket) {
    // Marked handled here, or a failed handshake nobody awaited is an
    // unhandled async error. Whoever does await [ready] still sees it fail.
    unawaited(_ready.future.catchError((Object _) {}));

    _sub = _socket.listen(
      _onChunk,
      onError: (Object e) => _fail(
        RpcStatusException(
          RpcStatus.unavailable,
          'Socket connection to $peer failed: $e',
        ),
      ),
      onDone: () {
        if (!_ready.isCompleted) {
          _fail(
            RpcStatusException(
              RpcStatus.unavailable,
              'Socket connection to $peer closed before its preface',
            ),
          );
          return;
        }
        unawaited(close());
      },
    );
    _backlog.attachReader(_sub);

    // Read backpressure: a paused consumer pauses the socket, so chunks wait
    // in the kernel rather than in `_incoming`. See [IRpcChannel.incoming].
    _incoming
      ..onPause = _sub.pause
      ..onResume = _sub.resume;

    // A write that fails (the peer reset the connection) is reported on
    // `done` and on the stream being written, nowhere else. Unobserved, that
    // is an unhandled async error in the zone the socket was created in,
    // which in the root zone ends the isolate.
    void failed(Object e) => _fail(
      RpcStatusException(
        RpcStatus.unavailable,
        'Socket connection to $peer failed: $e',
      ),
    );
    unawaited(_socket.done.then((_) {}, onError: failed));
    // `addStream` and not `add`: dart:io pauses the stream it writes from
    // while the kernel is full, so what is still queued sits where the
    // backlog counts it.
    _writing = _backlog
        .pipe(_out.stream, _socket)
        .then((_) {}, onError: failed);

    if (prefaceTimeout != null) {
      _prefaceTimer = Timer(
        prefaceTimeout,
        () => _fail(
          RpcStatusException(
            RpcStatus.unavailable,
            'No preface from $peer within $prefaceTimeout',
          ),
        ),
      );
    }

    _out.add(preface);
  }

  /// The first bytes each side writes: `rpcsock` and a protocol version.
  ///
  /// A peer with the same seven bytes and another version is an rpc_dart
  /// socket of a different protocol revision, which is reported as such.
  static final Uint8List preface = Uint8List.fromList([
    ...'rpcsock'.codeUnits,
    protocolVersion,
  ]);

  /// The wire revision this channel speaks.
  static const int protocolVersion = 1;

  /// Unsent bytes past which this side stops reading the peer, or null.
  final int? maxWriteBacklogBytes;

  final Socket _socket;
  final Duration _closeTimeout;
  final RpcWriteBacklog _backlog;
  late final StreamSubscription<Uint8List> _sub;
  Timer? _prefaceTimer;

  /// Synchronous, so a write the kernel can take now is not held a microtask.
  final StreamController<List<int>> _out = StreamController<List<int>>(
    sync: true,
  );
  late final Future<void> _writing;

  /// Single-subscription, so frames that arrive before the frame channel
  /// subscribes are buffered rather than dropped.
  final StreamController<Uint8List> _incoming = StreamController<Uint8List>();

  final Completer<void> _ready = Completer<void>();
  final Completer<void> _done = Completer<void>();
  final Uint8List _peerPreface = Uint8List(preface.length);
  int _prefaceSeen = 0;
  bool _closed = false;

  /// The remote end, for logs: the socket path for a Unix socket,
  /// `address:port` for TCP. Read at construction, because a destroyed socket
  /// throws on `remoteAddress`.
  final String peer;

  /// Completes once the peer's preface has arrived intact. Fails with an
  /// [RpcStatusException] when it never will: UNAVAILABLE when the connection
  /// ended or the wait timed out, FAILED_PRECONDITION for another protocol
  /// version, UNKNOWN for a peer that is not an rpc_dart socket at all.
  Future<void> get ready => _ready.future;

  /// Completes once this channel has closed, whoever closed it.
  Future<void> get done => _done.future;

  @override
  bool get isClosed => _closed;

  @override
  Stream<Uint8List> get incoming => _incoming.stream;

  void _onChunk(Uint8List chunk) {
    var data = chunk;
    if (!_ready.isCompleted) {
      var i = 0;
      while (i < data.length && _prefaceSeen < preface.length) {
        _peerPreface[_prefaceSeen++] = data[i++];
      }
      if (_prefaceSeen < preface.length) return;
      final mismatch = _checkPreface();
      if (mismatch != null) {
        _fail(mismatch);
        return;
      }
      _prefaceTimer?.cancel();
      _ready.complete();
      if (i == data.length) return;
      // A view, not a copy: the chunk is dart:io's fresh list, handed over
      // whole and never written to again, which is what [incoming] requires.
      data = Uint8List.sublistView(data, i);
    }
    if (!_incoming.isClosed) _incoming.add(data);
  }

  RpcStatusException? _checkPreface() {
    for (var i = 0; i < preface.length - 1; i++) {
      if (_peerPreface[i] != preface[i]) {
        return RpcStatusException(
          RpcStatus.unknown,
          'The peer at $peer is not an rpc_dart socket: unexpected preface',
        );
      }
    }
    final version = _peerPreface[preface.length - 1];
    if (version != protocolVersion) {
      return RpcStatusException(
        RpcStatus.failedPrecondition,
        'The peer at $peer speaks rpc_dart socket protocol $version, this side '
        'speaks $protocolVersion',
      );
    }
    return null;
  }

  /// Ends the channel on a transport failure, reporting [error] to [ready] if
  /// the handshake is still open, and to every call.
  ///
  /// Calls may start before the handshake answers, so a wrong preface has to
  /// reach them too: otherwise they see only the end of the stream and report
  /// a retryable UNAVAILABLE for a peer that will never be the right one.
  void _fail(RpcStatusException error) {
    if (_closed) return;
    if (!_ready.isCompleted) _ready.completeError(error);
    // A transport failure has to reach every call as a status: a retry
    // interceptor keys off the gRPC code, and a bare SocketException is not
    // one. Buffered if nothing listens yet, and dropped with the controller.
    if (!_incoming.isClosed) _incoming.addError(error);
    unawaited(close());
  }

  @override
  Future<void> send(Uint8List data) async {
    if (_closed) return;
    _out.add(data);
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _prefaceTimer?.cancel();
    if (!_ready.isCompleted) {
      _ready.completeError(
        RpcStatusException(
          RpcStatus.unavailable,
          'Socket connection to $peer closed before its preface',
        ),
      );
    }
    // NOT awaited: closing a single-subscription controller nobody listened to
    // never completes, so an unwrapped channel would hang here.
    if (!_incoming.isClosed) unawaited(_incoming.close());
    try {
      await _sub.cancel();
    } catch (_) {}
    // Ending `_out` ends the write once dart:io has taken all of it. Not
    // awaited: after a failed write nobody listens, and it never completes.
    unawaited(_out.close());
    try {
      // Writes what is queued, then FIN. A trailer sent just before close
      // must still reach the peer, which `destroy` alone would not guarantee.
      await _writing.then((_) => _socket.close()).timeout(_closeTimeout);
    } catch (_) {
      // Timed out or failed: the peer is not reading, or is gone.
    }
    _socket.destroy();
    if (!_done.isCompleted) _done.complete();
  }

  static String _describe(Socket socket) {
    try {
      final remote = socket.remoteAddress;
      if (remote.type == InternetAddressType.unix) return remote.address;
      return '${remote.address}:${socket.remotePort}';
    } catch (_) {
      return 'unknown peer';
    }
  }
}
