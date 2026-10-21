// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';
import 'dart:io';

import 'package:rpc_dart/transport.dart';

/// [IRpcChannel] over a `dart:io` [Socket]: the socket's byte stream as a raw
/// pipe.
///
/// A socket has no message boundaries, and none are needed:
/// `RpcFrameMultiplexedChannel`, which [RpcChannelTransport.fromChannel] puts
/// on top, reassembles frames from arbitrary chunks. That channel also opens
/// the connection with its preface, which is how each side learns that the
/// other is rpc_dart, and of which version.
///
/// **Writes never wait; reads do.** [send] queues and returns. Flow control
/// bounds DATA, but not what a call is answered with outside it (metadata,
/// trailers), so a peer that never reads and keeps starting calls would grow
/// the queue without end. With [maxWriteBacklogBytes] set, a queue past it
/// stops this side reading the peer until the queue has halved.
///
/// **A closing peer cannot say why.** A raw socket has no close code, so a
/// connection closed for a protocol violation reaches the peer as an ordinary
/// end of stream, which its caller reports as UNAVAILABLE. A message past the
/// size limit is the exception: its RESOURCE_EXHAUSTED trailer is written
/// before the close, and [closeForOversize] makes sure it arrives.
class RpcSocketChannel implements IRpcChannel, IRpcChannelOversizeClose {
  /// Wraps [socket], which this channel then owns: [close] closes it.
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
    Duration closeTimeout = const Duration(seconds: 5),
    this.maxWriteBacklogBytes,
  }) : _socket = socket,
       _closeTimeout = closeTimeout,
       _backlog = RpcWriteBacklog(maxUnsentBytes: maxWriteBacklogBytes),
       peer = _describe(socket) {
    _sub = _socket.listen(
      (chunk) {
        // The chunk is dart:io's fresh list, handed over whole and never
        // written to again, which is what [incoming] requires.
        if (!_incoming.isClosed) _incoming.add(chunk);
      },
      onError: (Object e) => _fail(
        RpcStatusException(
          RpcStatus.unavailable,
          'Socket connection to $peer failed: $e',
        ),
      ),
      onDone: () => unawaited(close()),
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
  }

  /// Unsent bytes past which this side stops reading the peer, or null.
  final int? maxWriteBacklogBytes;

  final Socket _socket;
  final Duration _closeTimeout;
  final RpcWriteBacklog _backlog;
  late final StreamSubscription<Uint8List> _sub;

  /// Synchronous, so a write the kernel can take now is not held a microtask.
  final StreamController<List<int>> _out = StreamController<List<int>>(
    sync: true,
  );
  late final Future<void> _writing;

  /// Single-subscription, so bytes that arrive before the frame channel
  /// subscribes are buffered rather than dropped.
  final StreamController<Uint8List> _incoming = StreamController<Uint8List>();

  final Completer<void> _done = Completer<void>();
  bool _closed = false;

  /// The remote end, for logs: the socket path for a Unix socket,
  /// `address:port` for TCP. Read at construction, because a destroyed socket
  /// throws on `remoteAddress`.
  final String peer;

  /// Completes once this channel has closed, whoever closed it.
  Future<void> get done => _done.future;

  @override
  bool get isClosed => _closed;

  @override
  Stream<Uint8List> get incoming => _incoming.stream;

  /// Ends the channel on a transport failure, reporting [error] to every
  /// call.
  ///
  /// A transport failure has to reach every call as a status: a retry
  /// interceptor keys off the gRPC code, and a bare SocketException is not
  /// one. Buffered if nothing listens yet, and dropped with the controller.
  void _fail(RpcStatusException error) {
    if (_closed) return;
    if (!_incoming.isClosed) _incoming.addError(error);
    unawaited(close());
  }

  /// Frames of one event-loop turn go out as one write, see
  /// [RpcWriteCoalescer].
  late final RpcWriteCoalescer _writes = RpcWriteCoalescer(_out.add);

  @override
  Future<void> send(Uint8List data) async {
    if (_closed) return;
    _writes.add(data);
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _writes.flush();
    _closed = true;
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

  /// The most of a refused peer's remaining bytes [closeForOversize] reads
  /// and drops: twice the default `maxMessageLengthBytes`, so the rest of
  /// one message past the default limit fits.
  static const int _maxOversizeDrainBytes = 32 * 1024 * 1024;

  /// Closes because the peer's message was larger than the policy allows,
  /// letting the answer already queued reach the peer.
  ///
  /// The peer may still be writing that message. Destroying the socket with
  /// its bytes unread makes the kernel reset the connection, and a reset
  /// discards what the peer has received but not read yet: the
  /// RESOURCE_EXHAUSTED trailer written just before. The peer's caller is
  /// left with its own failed write, UNAVAILABLE, which a retry repeats with
  /// the same message.
  ///
  /// So the queued writes go out with FIN, as in [close], and the peer's
  /// remaining bytes are read and dropped until it closes its side. Bounded
  /// by [_maxOversizeDrainBytes] and by the close timeout, so a peer that
  /// keeps sending is cut off as before.
  @override
  Future<void> closeForOversize(String reason) async {
    if (_closed) return;
    _writes.flush();
    _closed = true;
    if (!_incoming.isClosed) unawaited(_incoming.close());

    final peerClosed = Completer<void>();
    void stop() {
      if (!peerClosed.isCompleted) peerClosed.complete();
    }

    var drained = 0;
    _sub
      ..onData((chunk) {
        drained += chunk.length;
        if (drained > _maxOversizeDrainBytes) stop();
      })
      ..onError((Object _) => stop())
      ..onDone(stop);
    // The reader may be paused by a full write backlog or by a consumer that
    // stopped reading; a paused reader drains nothing.
    while (_sub.isPaused) {
      _sub.resume();
    }

    unawaited(_out.close());
    try {
      await _writing
          .then((_) => _socket.close())
          .then((_) => peerClosed.future)
          .timeout(_closeTimeout);
    } catch (_) {
      // Timed out or failed: the peer is not reading, or is gone.
    }
    try {
      await _sub.cancel();
    } catch (_) {}
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
