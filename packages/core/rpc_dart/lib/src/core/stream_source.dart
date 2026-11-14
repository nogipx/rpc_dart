// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';

/// Owns one source subscription, without adding a controller or a queue.
///
/// Start, pause and teardown share the same discipline in relays and bounded
/// buffers. Cancelling attempts source cleanup but never awaits user work.
final class StreamSource<T> {
  /// Defers [source] until [start]. A cancelled source is never started.
  StreamSource({
    required Stream<T> Function() source,
    required void Function(T) onData,
    required void Function(Object, StackTrace) onError,
    required void Function() onDone,
    void Function(Object, StackTrace)? onCancelFailed,
    this.pauseBroadcast = true,
  }) : _source = source,
       _onData = onData,
       _onError = onError,
       _onDone = onDone,
       _onCancelFailed = onCancelFailed;

  /// Owns an existing stream without retaining it after subscription starts.
  StreamSource.fromStream(
    Stream<T> stream, {
    required void Function(T) onData,
    required void Function(Object, StackTrace) onError,
    required void Function() onDone,
    void Function(Object, StackTrace)? onCancelFailed,
    bool pauseBroadcast = true,
  }) : this(
         source: _factory(stream),
         onData: onData,
         onError: onError,
         onDone: onDone,
         onCancelFailed: onCancelFailed,
         pauseBroadcast: pauseBroadcast,
       );

  static Stream<T> Function() _factory<T>(Stream<T> stream) =>
      () => stream;

  /// Whether pausing should pause a broadcast subscription too.
  /// A bounded buffer instead keeps receiving broadcasts into its own queue.
  final bool pauseBroadcast;
  Stream<T> Function()? _source;
  void Function(T)? _onData;
  void Function(Object, StackTrace)? _onError;
  void Function()? _onDone;
  void Function(Object, StackTrace)? _onCancelFailed;
  StreamSubscription<T>? _subscription;
  bool _started = false;
  bool _stopped = false;
  bool _paused = false;
  bool _broadcast = false;

  /// Whether this owner has released the source and its callback captures.
  bool get isClosed => _stopped;

  /// Invokes the factory and listens once. Factory/listen failures are events.
  void start() {
    if (_started || _stopped) return;
    _started = true;
    final make = _source!;
    _source = null;
    try {
      final incoming = make();
      if (_stopped) return;
      _broadcast = incoming.isBroadcast;
      final cancelFailed = _onCancelFailed;
      final subscription = incoming.listen(
        (event) => _onData?.call(event),
        onError: (Object error, StackTrace stack) =>
            _onError?.call(error, stack),
        onDone: _complete,
      );
      if (_stopped) {
        _cancel(subscription, cancelFailed);
      } else {
        _subscription = subscription;
        if (_paused && (pauseBroadcast || !_broadcast)) subscription.pause();
      }
    } on Object catch (error, stack) {
      try {
        _onError?.call(error, stack);
      } finally {
        _complete();
      }
    }
  }

  /// Pauses demand. A pause requested during listen is applied afterwards.
  void pause() {
    if (_stopped || _paused) return;
    _paused = true;
    if (pauseBroadcast || !_broadcast) _subscription?.pause();
  }

  /// Resumes demand after a matching [pause].
  void resume() {
    if (_stopped || !_paused) return;
    _paused = false;
    if (pauseBroadcast || !_broadcast) _subscription?.resume();
  }

  void _complete() {
    if (_stopped) return;
    final done = _onDone;
    _release();
    done?.call();
  }

  void _release() {
    _stopped = true;
    _subscription = null;
    _source = null;
    _onData = null;
    _onError = null;
    _onDone = null;
    _onCancelFailed = null;
  }

  /// Releases all owned references and attempts cancellation once.
  void cancel() {
    if (_stopped) return;
    final subscription = _subscription;
    final failed = _onCancelFailed;
    _release();
    if (subscription != null) _cancel(subscription, failed);
  }

  static void _cancel<T>(
    StreamSubscription<T> subscription,
    void Function(Object, StackTrace)? failed,
  ) {
    try {
      unawaited(
        subscription.cancel().catchError((Object e, StackTrace s) {
          failed?.call(e, s);
        }),
      );
    } on Object catch (error, stack) {
      failed?.call(error, stack);
    }
  }
}
