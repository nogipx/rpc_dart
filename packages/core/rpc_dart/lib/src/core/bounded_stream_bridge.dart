// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';
import 'dart:collection';

import 'buffer_budget.dart';
import 'stream_source.dart';

/// Limits on one application queue; null disables an individual bound.
final class StreamBufferLimits {
  /// Bounds pending events, their supplied weights and one event's weight.
  const StreamBufferLimits({this.items, this.bytes, this.elementBytes});

  /// Maximum pending event count.
  final int? items;

  /// Maximum sum of pending event weights.
  final int? bytes;

  /// Maximum supplied weight of one event.
  final int? elementBytes;
}

/// Payload-free counters for one bounded bridge.
final class StreamBridgeStats {
  /// Creates empty counters. The bridge is their sole writer while active.
  StreamBridgeStats();

  /// Admitted event count.
  int items = 0;

  /// Sum of admitted event weights.
  int bytes = 0;

  /// Events handed to the consumer.
  int delivered = 0;

  /// Events currently queued.
  int pendingItems = 0;

  /// Sum of weights currently queued.
  int pendingBytes = 0;

  /// Largest pending event count.
  int peakItems = 0;

  /// Largest pending weight.
  int peakBytes = 0;

  /// Whether the consumer has paused delivery.
  bool paused = false;

  /// Whether the bridge has released its resources.
  bool closed = false;

  /// Whether the source completed, possibly before draining its queue.
  bool sourceDone = false;

  /// Whether the consumer detached without a terminal notification.
  bool cancelled = false;
}

/// A lazy, terminal-on-error bridge with one explicitly bounded queue.
///
/// Single-subscription sources receive demand. Broadcast sources keep running
/// into this queue rather than an unbounded paused subscription. Event weight
/// is supplied by the caller; this class performs no serialization.
final class BoundedStreamBridge<T> {
  /// Starts [source] on first listen, by default on the next microtask.
  BoundedStreamBridge({
    required Stream<T> Function() source,
    required int Function(T) weigh,
    required StreamBufferLimits limits,
    StreamBridgeStats? stats,
    bool pauseSource = true,
    bool deferStart = true,
    void Function()? onStart,
    Object Function()? overflowError,
    Object Function(Object, StackTrace)? sourceError,
    Object Function(Object, StackTrace)? elementError,
    void Function(int, int, Object?)? onClosed,
  }) : _weigh = weigh,
       _limits = limits,
       _stats = stats,
       _pauseSource = pauseSource,
       _deferStart = deferStart,
       _onStart = onStart,
       _overflowError = overflowError,
       _sourceError = sourceError,
       _elementError = elementError,
       _onClosed = onClosed,
       _budget = RpcBufferBudget(
         limitBytes: limits.bytes,
         limitEvents: limits.items,
       ) {
    _input = StreamSource<T>(
      source: source,
      onData: _receive,
      onError: _failed,
      onDone: _sourceDone,
      pauseBroadcast: false,
    );
    _out = StreamController<T>(
      sync: true,
      onListen: _listen,
      onPause: _pause,
      onResume: _resume,
      onCancel: () => _finish(notify: false),
    );
  }
  late final StreamSource<T> _input;
  late final StreamController<T> _out;
  final StreamBufferLimits _limits;
  final RpcBufferBudget _budget;
  final bool _pauseSource;
  final bool _deferStart;
  final _pending = Queue<(T, int)>();
  StreamBridgeStats? _stats;
  int Function(T)? _weigh;
  void Function()? _onStart;
  Object Function()? _overflowError;
  Object Function(Object, StackTrace)? _sourceError;
  Object Function(Object, StackTrace)? _elementError;
  void Function(int, int, Object?)? _onClosed;
  bool _stopped = false;
  bool _paused = false;
  bool _ended = false;
  int _items = 0;
  int _bytes = 0;

  /// Its single-subscription output.
  Stream<T> get stream => _out.stream;

  /// Whether the bridge has released its resources.
  bool get isClosed => _stopped;

  void _listen() {
    if (_deferStart) {
      scheduleMicrotask(_start);
    } else {
      _start();
    }
  }

  void _start() {
    if (_stopped) return;
    final start = _onStart;
    _onStart = null;
    try {
      start?.call();
      if (!_stopped) _input.start();
    } on Object catch (error, stack) {
      _failed(error, stack);
    }
  }

  void _pause() {
    _paused = true;
    _stats?.paused = true;
    _flow();
  }

  void _resume() {
    _paused = false;
    _stats?.paused = false;
    _drain();
    _flow();
  }

  void _flow() {
    if (_stopped || !_pauseSource) return;
    // One read ahead lets an empty source finish even while paused.
    if (_paused && _pending.isNotEmpty) {
      _input.pause();
    } else {
      _input.resume();
    }
  }

  void _sourceDone() {
    _ended = true;
    _stats?.sourceDone = true;
    _drain();
  }

  void _receive(T value) {
    if (_stopped) return;
    try {
      final weight = _weigh!(value);
      if (_stopped) return;
      if ((_limits.elementBytes != null && weight > _limits.elementBytes!) ||
          !_budget.admit(weight)) {
        fail(
          _overflowError?.call() ?? StateError('stream buffer limit exceeded'),
        );
        return;
      }
      _items++;
      _bytes += weight;
      final stats = _stats;
      if (stats != null) {
        stats.items = _items;
        stats.bytes = _bytes;
        stats.pendingItems = _budget.events;
        stats.pendingBytes = _budget.bytes;
        if (_budget.events > stats.peakItems) stats.peakItems = _budget.events;
        if (_budget.bytes > stats.peakBytes) stats.peakBytes = _budget.bytes;
      }
      if (!_paused && _pending.isEmpty) {
        _deliver(value, weight);
      } else {
        _pending.add((value, weight));
        _drain();
      }
      _flow();
    } on Object catch (error, stack) {
      fail(_elementError?.call(error, stack) ?? error, stack);
    }
  }

  void _drain() {
    while (!_stopped && !_paused && _pending.isNotEmpty) {
      final (value, weight) = _pending.removeFirst();
      _deliver(value, weight);
    }
    if (!_stopped && _ended && _pending.isEmpty) _finish();
  }

  void _deliver(T value, int weight) {
    _budget.release(weight);
    final stats = _stats;
    if (stats != null) {
      stats.delivered++;
      stats.pendingItems = _budget.events;
      stats.pendingBytes = _budget.bytes;
    }
    _out.add(value);
  }

  void _failed(Object error, StackTrace stack) =>
      fail(_sourceError?.call(error, stack) ?? error, stack);

  /// Ends with a terminal failure, dropping queued data immediately.
  void fail(Object error, [StackTrace? stack]) =>
      _finish(error: error, stack: stack);

  /// Ends normally, releasing queued data and the source immediately.
  void close() => _finish();

  void _finish({Object? error, StackTrace? stack, bool notify = true}) {
    if (_stopped) return;
    _stopped = true;
    final stats = _stats;
    if (stats != null) {
      stats.closed = true;
      stats.cancelled = !notify;
      stats.paused = false;
      stats.pendingItems = 0;
      stats.pendingBytes = 0;
    }
    final closed = _onClosed;
    _stats = null;
    _onClosed = null;
    _onStart = null;
    _weigh = null;
    _overflowError = null;
    _sourceError = null;
    _elementError = null;
    _input.cancel();
    _pending.clear();
    _budget.clear();
    try {
      closed?.call(_items, _bytes, error);
    } finally {
      if (notify) {
        scheduleMicrotask(() {
          if (error != null) _out.addError(error, stack);
          unawaited(_out.close());
        });
      }
    }
  }
}
