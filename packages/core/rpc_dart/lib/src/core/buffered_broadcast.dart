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
///  * it never grows past [maxPendingEvents]. If that bound is hit while still
///    unlistened — a producer feeding a controller nobody consumes, i.e. a
///    misuse/abandoned transport — further events are dropped and [onOverflow]
///    fires once, so memory stays bounded instead of growing without limit.
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
  /// is attached; [onOverflow] fires once if that bound is exceeded.
  BufferedBroadcastController({this.maxPendingEvents = 4096, this.onOverflow}) {
    _controller = StreamController<T>.broadcast(onListen: _flush);
  }

  /// Upper bound on events buffered while no listener is attached.
  final int maxPendingEvents;

  /// Called once when [maxPendingEvents] is first exceeded (diagnostics).
  final void Function()? onOverflow;

  late final StreamController<T> _controller;
  final Queue<_BufferedItem<T>> _pending = Queue<_BufferedItem<T>>();
  final Completer<void> _doneCompleter = Completer<void>();
  bool _closed = false;
  bool _overflowed = false;

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
      _enqueue(_BufferedItem<T>.data(event));
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
  @override
  Future<void> addStream(Stream<T> source, {bool? cancelOnError}) {
    final completer = Completer<void>();
    source.listen(
      add,
      onError: addError,
      onDone: completer.complete,
      cancelOnError: cancelOnError ?? false,
    );
    return completer.future;
  }

  void _enqueue(_BufferedItem<T> item) {
    if (_pending.length >= maxPendingEvents) {
      if (!_overflowed) {
        _overflowed = true;
        onOverflow?.call();
      }
      return; // bound memory: nobody is draining the queue
    }
    _pending.add(item);
  }

  void _flush() {
    while (_pending.isNotEmpty &&
        _controller.hasListener &&
        !_controller.isClosed) {
      final item = _pending.removeFirst();
      if (item.isError) {
        _controller.addError(item.error!, item.stackTrace);
      } else {
        _controller.add(item.data as T);
      }
    }
    _overflowed = false;
  }

  /// Clears the buffer and closes the underlying controller.
  @override
  Future<void> close() async {
    if (_closed) {
      return _doneCompleter.future;
    }
    _closed = true;
    _pending.clear();
    if (!_controller.isClosed) await _controller.close();
    if (!_doneCompleter.isCompleted) _doneCompleter.complete();
  }
}

class _BufferedItem<T> {
  _BufferedItem.data(this.data)
    : isError = false,
      error = null,
      stackTrace = null;
  _BufferedItem.error(this.error, this.stackTrace)
    : isError = true,
      data = null;

  final bool isError;
  final T? data;
  final Object? error;
  final StackTrace? stackTrace;
}
