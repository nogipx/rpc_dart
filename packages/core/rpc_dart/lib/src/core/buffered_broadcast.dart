// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';
import 'dart:collection';

/// A broadcast stream controller that **retains events while it has no
/// listener** and replays them, in arrival order, to the first subscriber.
///
/// A plain `StreamController.broadcast()` silently drops events delivered while
/// it has no listener. Transports start consuming the connection as soon as it
/// is up, but the RPC pipeline subscribes to [stream] slightly later — so the
/// first inbound frames (e.g. a client-stream's leading chunk on a cold
/// connection) would be lost. This controller queues them and flushes on the
/// first `listen`, then forwards live events straight through.
///
/// This is the buffering core of HTTP/2's `StreamMessageQueueIn` (hold until a
/// listener exists, dispatch on listen), adapted to a broadcast controller so
/// the several consumers a transport exposes can all attach.
///
/// Buffering applies ONLY while there is no listener: broadcast streams have no
/// per-listener backpressure, so once listened, events pass straight through.
/// Detach/re-attach is handled too — events delivered between listeners are
/// queued and flushed when the next listener attaches.
///
/// Leak-safety:
///  * the pending queue is cleared on [close];
///  * it never grows past [maxPendingEvents] events, NOR past
///    [maxPendingBytes] when a [sizeOf] is supplied. If either bound is hit
///    while still unlistened — a producer feeding a controller nobody consumes,
///    i.e. a misuse/abandoned transport — further events are dropped and
///    [onOverflow] fires once.
///
/// **Both dimensions are needed, and the count alone was the bug.** A bound on
/// events says nothing about bytes: the neighbouring limit,
/// `RpcSecurityPolicy.maxMessageLengthBytes`, bounds ONE message at 16 MiB by
/// default, so 4096 events admitted up to 64 GiB of payload while this class's
/// doc claimed memory stayed bounded. Measured with the queue's own counter,
/// 4096 messages at three sizes:
///
///     16 KiB each   pending=4096   retained   64 MiB
///     64 KiB each   pending=4096   retained  256 MiB
///    256 KiB each   pending=4096   retained 1024 MiB
///
/// — the count never moves, the bytes scale linearly. Through a real transport
/// with nothing subscribed: RSS +549 MiB against +2 MiB with a listener
/// attached.
///
/// Implements [StreamSink] (the writable half of a `StreamController`) so it
/// can be used polymorphically as a sink and exposes [stream] like a controller
/// does. It deliberately does NOT implement the full `StreamController`: that
/// interface exposes settable `onListen`/`onPause`/`onResume`/`onCancel`, and
/// this type uses `onListen` internally to flush the buffer — exposing it would
/// let callers override the flush and break the buffering invariant.
class BufferedBroadcastController<T> implements StreamSink<T> {
  /// Creates a buffered broadcast controller.
  ///
  /// [maxPendingEvents] bounds how many events are retained while no listener
  /// is attached; [maxPendingBytes] bounds their total size, measured with
  /// [sizeOf]. [onOverflow] fires once if either bound is exceeded.
  ///
  /// [sizeOf] is optional because this type is generic and cannot know how to
  /// weigh a `T`. Without it the byte bound cannot be applied and only the
  /// count applies — which is what every caller here used to get.
  BufferedBroadcastController({
    this.maxPendingEvents = 4096,
    this.maxPendingBytes = 16 * 1024 * 1024,
    this.sizeOf,
    this.onOverflow,
  }) {
    _controller = StreamController<T>.broadcast(onListen: _flush);
  }

  /// Upper bound on events buffered while no listener is attached.
  final int maxPendingEvents;

  /// Upper bound on the total size of those events, when [sizeOf] is given.
  ///
  /// 16 MiB is generous for what this queue is FOR — the handful of leading
  /// frames that arrive before the pipeline subscribes — and it caps the damage
  /// at one message's worth rather than 4096 of them.
  final int maxPendingBytes;

  /// Weighs a pending event, in bytes. Null disables the byte bound.
  final int Function(T event)? sizeOf;

  /// Called once when either bound is first exceeded (diagnostics).
  final void Function()? onOverflow;

  /// Total size of the buffered events, when [sizeOf] is given.
  int _pendingBytes = 0;

  late final StreamController<T> _controller;
  final Queue<_BufferedItem<T>> _pending = Queue<_BufferedItem<T>>();

  /// In-flight [addStream] pipes, so [close] can cancel them and settle their
  /// futures. Without this the subscription was dropped on the floor: the
  /// caller had no handle to it, so a pipe outlived the sink and kept draining
  /// its source forever into a closed (no-op) controller.
  final List<({StreamSubscription<T> sub, void Function() finish})> _pipes = [];
  final Completer<void> _doneCompleter = Completer<void>();
  bool _closed = false;
  bool _overflowed = false;
  int _droppedCount = 0;

  /// The broadcast stream consumers listen to.
  Stream<T> get stream => _controller.stream;

  /// Completes when this sink is closed.
  @override
  Future<void> get done => _doneCompleter.future;

  /// Whether at least one subscriber is currently attached.
  bool get hasListener => _controller.hasListener;

  /// Whether this controller has been closed.
  bool get isClosed => _closed || _controller.isClosed;

  /// Number of events currently buffered awaiting a listener (diagnostics).
  int get pendingCount => _pending.length;

  /// Adds a data event: delivered immediately when listened, else queued.
  @override
  void add(T event) {
    if (isClosed) return;
    if (_controller.hasListener) {
      _controller.add(event);
    } else {
      _enqueue(_BufferedItem<T>.data(event, sizeOf?.call(event) ?? 0));
    }
  }

  /// Adds an error event, preserving order relative to [add].
  @override
  void addError(Object error, [StackTrace? stackTrace]) {
    if (isClosed) return;
    if (_controller.hasListener) {
      _controller.addError(error, stackTrace);
    } else {
      _enqueue(_BufferedItem<T>.error(error, stackTrace));
    }
  }

  /// Pipes [source] into this sink (events and errors), completing when the
  /// source is done. Same buffering semantics as [add]/[addError].
  ///
  /// The subscription is owned by this controller and cancelled by [close], so
  /// a pipe left in flight at shutdown does not keep draining its source. The
  /// returned future completes on close as well as on source completion.
  @override
  Future<void> addStream(Stream<T> source, {bool? cancelOnError}) {
    if (isClosed) return Future<void>.value();

    final stopOnError = cancelOnError ?? false;
    final completer = Completer<void>();
    StreamSubscription<T>? sub;

    void finish() {
      final current = sub;
      if (current != null) _pipes.removeWhere((p) => identical(p.sub, current));
      if (!completer.isCompleted) completer.complete();
    }

    final subscription = source.listen(
      add,
      onError: (Object error, StackTrace stackTrace) {
        addError(error, stackTrace);
        // cancelOnError tears the subscription down on the first error, so
        // onDone never fires. Without this the returned future would hang
        // forever and any `await sink.addStream(...)` would never return.
        if (stopOnError) finish();
      },
      onDone: finish,
      cancelOnError: stopOnError,
    );
    sub = subscription;

    // A sync source can finish inside listen(), before `sub` was assigned.
    if (completer.isCompleted) {
      unawaited(subscription.cancel());
    } else {
      _pipes.add((sub: subscription, finish: finish));
    }
    return completer.future;
  }

  void _enqueue(_BufferedItem<T> item) {
    final bytes = item.bytes;
    // EITHER bound. The count alone let 4096 events of up to
    // maxMessageLengthBytes through -- 64 GiB at the defaults.
    if (_pending.length >= maxPendingEvents ||
        (bytes > 0 && _pendingBytes + bytes > maxPendingBytes)) {
      _droppedCount++;
      if (!_overflowed) {
        _overflowed = true;
        onOverflow?.call();
      }
      return; // bound memory: nobody is draining the queue
    }
    _pendingBytes += bytes;
    _pending.add(item);
  }

  void _flush() {
    while (_pending.isNotEmpty &&
        _controller.hasListener &&
        !_controller.isClosed) {
      final item = _pending.removeFirst();
      _pendingBytes -= item.bytes;
      if (item.isError) {
        _controller.addError(item.error!, item.stackTrace);
      } else {
        _controller.add(item.data as T);
      }
    }
    // Overflow is FATAL. Reaching maxPendingEvents means no consumer ever
    // drained the buffer (a buffer with a listener passes events straight
    // through and never grows) — the connection is effectively dead and the
    // retained prefix is now followed by a hole. Deliver the survivors, then
    // surface the loss as an error and CLOSE, so the consumer terminates and
    // re-establishes the connection instead of silently processing a gappy
    // stream. Continuing would just propagate corruption.
    if (_droppedCount > 0 && _controller.hasListener && !_controller.isClosed) {
      final dropped = _droppedCount;
      _droppedCount = 0;
      _overflowed = false;
      _controller.addError(
        StateError(
          'BufferedBroadcastController dropped $dropped event(s): more than '
          'maxPendingEvents ($maxPendingEvents) buffered before any listener '
          'attached. The stream is closed; re-establish the connection.',
        ),
      );
      unawaited(close());
    } else {
      _overflowed = false;
    }
  }

  /// Clears the buffer and closes the underlying controller.
  @override
  Future<void> close() async {
    if (_closed) {
      return _doneCompleter.future;
    }
    _closed = true;
    _pending.clear();
    _pendingBytes = 0;

    // Cancel any in-flight addStream pipes and settle their futures, so an
    // `await sink.addStream(...)` that was still running returns instead of
    // hanging on a source nobody is consuming any more.
    final pipes = List.of(_pipes);
    _pipes.clear();
    for (final pipe in pipes) {
      await pipe.sub.cancel();
      pipe.finish();
    }

    if (!_controller.isClosed) await _controller.close();
    if (!_doneCompleter.isCompleted) _doneCompleter.complete();
  }
}

class _BufferedItem<T> {
  _BufferedItem.data(this.data, this.bytes)
    : isError = false,
      error = null,
      stackTrace = null;
  _BufferedItem.error(this.error, this.stackTrace)
    : isError = true,
      data = null,
      bytes = 0;

  final bool isError;
  final T? data;
  final Object? error;
  final StackTrace? stackTrace;

  /// What this item weighs against `maxPendingBytes`; 0 when unweighed, so
  /// removing it is exact rather than a running estimate.
  final int bytes;
}
