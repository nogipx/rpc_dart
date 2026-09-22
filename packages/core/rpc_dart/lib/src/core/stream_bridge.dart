// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';

/// A [StreamController] mirroring a source this library does not own.
///
/// The class is decided by ownership: a stream the library built cannot park on
/// cancel, one handed in by a user — or built from a user's `async*` — can.
/// Every bridge over such a source owes the same four clauses, and four
/// consecutive rounds each found a different copy missing a different one.
///
/// A bridge has **two** cancel paths and both must drop the source's cancel
/// Future:
///
/// - **consumer-cancel** — the downstream listener cancels. `StreamController`
///   awaits whatever `onCancel` returns, so returning the source's cancel hands
///   the consumer the source's own stall: measured as an unbounded hang against
///   6 ms with the await removed.
/// - **owner-teardown** — [cancelSource] / [close], called by the scope, timer
///   or lifecycle that owns the bridge. Awaiting here blocks a shutdown.
///
/// The other two: forward pause/resume, or a slow consumer never slows the
/// source and the controller buffers without bound; and close the controller
/// when the source is done, or the consumer waits on a call that is over.
final class StreamBridge<T> {
  final Stream<T> _source;
  final void Function()? _onSourceDone;
  final void Function(Object error, StackTrace stackTrace)? _onSourceError;
  final void Function()? _onConsumerCancel;
  final void Function(Object error, StackTrace stackTrace)? _onCancelFailed;

  late final StreamController<T> _controller;
  StreamSubscription<T>? _subscription;

  /// Bridges [source].
  ///
  /// [subscribeOnFirstListen] defers subscribing until someone listens, for a
  /// bridge whose subscription STARTS something — a tracked call, a metered
  /// stream. Eager (the default) is for a bridge whose source must be observed
  /// whether or not the consumer ever arrives.
  ///
  /// The hooks run before the bridge's own handling: [onFirstListen] before
  /// subscribing, [onConsumerCancel] before the source is cancelled,
  /// [onSourceDone] before the controller closes. [onCancelFailed] receives a
  /// cancel that rejected — without it the rejection is swallowed, with it the
  /// owner can log; either way it never reaches the zone.
  StreamBridge({
    required Stream<T> source,
    bool subscribeOnFirstListen = false,
    void Function()? onFirstListen,
    void Function()? onSourceDone,
    void Function(Object error, StackTrace stackTrace)? onSourceError,
    void Function()? onConsumerCancel,
    void Function(Object error, StackTrace stackTrace)? onCancelFailed,
  }) : _source = source,
       _onSourceDone = onSourceDone,
       _onSourceError = onSourceError,
       _onConsumerCancel = onConsumerCancel,
       _onCancelFailed = onCancelFailed {
    _controller = StreamController<T>(
      onListen: () {
        onFirstListen?.call();
        if (subscribeOnFirstListen) _subscribe();
      },
      onPause: () => _subscription?.pause(),
      onResume: () => _subscription?.resume(),
      // A block body, deliberately: an arrow would return cancelSource()'s
      // value, and the day that stops being void the consumer starts awaiting
      // the source again.
      onCancel: () {
        _onConsumerCancel?.call();
        cancelSource();
      },
    );
    if (!subscribeOnFirstListen) _subscribe();
  }

  /// The mirrored stream, to hand to the consumer.
  Stream<T> get stream => _controller.stream;

  /// Whether the mirrored stream is closed.
  bool get isClosed => _controller.isClosed;

  /// Drops the source subscription without waiting for it.
  ///
  /// Nulls the handle first, so a later pause/resume cannot reach a cancelled
  /// subscription and throw.
  void cancelSource() {
    final subscription = _subscription;
    _subscription = null;
    if (subscription == null) return;
    unawaited(
      subscription.cancel().catchError((Object error, StackTrace stackTrace) {
        _onCancelFailed?.call(error, stackTrace);
      }),
    );
  }

  /// Owner teardown: drops the source and ends the mirrored stream.
  void close() {
    cancelSource();
    if (!_controller.isClosed) unawaited(_controller.close());
  }

  void _subscribe() {
    _subscription = _source.listen(
      (event) {
        if (!_controller.isClosed) _controller.add(event);
      },
      onError: (Object error, StackTrace stackTrace) {
        _onSourceError?.call(error, stackTrace);
        if (!_controller.isClosed) _controller.addError(error, stackTrace);
      },
      onDone: () {
        _onSourceDone?.call();
        if (!_controller.isClosed) unawaited(_controller.close());
      },
      cancelOnError: false,
    );
  }
}
