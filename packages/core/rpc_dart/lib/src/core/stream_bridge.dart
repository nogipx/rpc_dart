// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';

import 'stream_source.dart';

/// Mirrors a source while forwarding demand and owning both cancellation paths.
///
/// This neutral relay preserves non-terminal source errors. It has no queue
/// budget; use `BoundedStreamBridge` when a producer cannot be paused safely.
final class StreamBridge<T> {
  /// Mirrors [source]. Eager subscription is the default; a cold operation can
  /// opt into [subscribeOnFirstListen]. Hooks run before forwarding the event.
  StreamBridge({
    required Stream<T> source,
    bool subscribeOnFirstListen = false,
    void Function()? onFirstListen,
    void Function()? onSourceDone,
    void Function(Object, StackTrace)? onSourceError,
    void Function()? onConsumerCancel,
    void Function(Object, StackTrace)? onCancelFailed,
  }) : _onFirstListen = onFirstListen,
       _onSourceDone = onSourceDone,
       _onSourceError = onSourceError,
       _onConsumerCancel = onConsumerCancel {
    _controller = StreamController<T>(
      onListen: () {
        if (_ended) return;
        final first = _onFirstListen;
        _onFirstListen = null;
        first?.call();
        if (!_ended && subscribeOnFirstListen) _input.start();
      },
      onPause: () => _input.pause(),
      onResume: () => _input.resume(),
      onCancel: () => _finish(notify: false),
    );
    _input = StreamSource<T>(
      source: _factory(source),
      onData: _controller.add,
      onError: (error, stack) {
        if (_ended) return;
        _onSourceError?.call(error, stack);
        if (!_ended) _controller.addError(error, stack);
      },
      onDone: () => _finish(sourceDone: true),
      onCancelFailed: onCancelFailed,
    );
    if (!subscribeOnFirstListen) _input.start();
  }
  static Stream<T> Function() _factory<T>(Stream<T> source) =>
      () => source;

  late final StreamSource<T> _input;
  late final StreamController<T> _controller;
  void Function()? _onFirstListen;
  void Function()? _onSourceDone;
  void Function(Object, StackTrace)? _onSourceError;
  void Function()? _onConsumerCancel;
  bool _ended = false;

  /// The mirrored single-subscription stream.
  Stream<T> get stream => _controller.stream;

  /// Whether the relay has ended.
  bool get isClosed => _ended;

  /// Stops the source without ending the output.
  void cancelSource() => _input.cancel();

  /// Ends the relay, without waiting for arbitrary source cleanup.
  void close() => _finish();

  /// Ends the relay with a terminal owner-supplied failure.
  void fail(Object error, [StackTrace? stackTrace]) =>
      _finish(error: error, stack: stackTrace);

  void _finish({
    bool notify = true,
    bool sourceDone = false,
    Object? error,
    StackTrace? stack,
  }) {
    if (_ended) return;
    _ended = true;
    final callback = sourceDone ? _onSourceDone : _onConsumerCancel;
    _onFirstListen = null;
    _onSourceDone = null;
    _onSourceError = null;
    _onConsumerCancel = null;
    _input.cancel();
    try {
      callback?.call();
    } finally {
      if (notify) {
        if (error != null) _controller.addError(error, stack);
        unawaited(_controller.close());
      }
    }
  }
}
