// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';

import '../logger/_index.dart';

/// Drives a [StreamSink]'s source into a call, one send at a time.
///
/// The counterpart of a bridge: a bridge mirrors a source OUT to a consumer,
/// a pump drives one IN to the wire. The clauses are its own, and four
/// consecutive rounds each found a different copy missing a different one.
///
/// - **Pause for the duration of each send.** `addStream` stops pulling while
///   this subscription is paused, so the producer holds one item instead of
///   however many it can offer. Without it the send sequence is an unbounded
///   queue in front of the transport, and flow control cannot throttle the
///   direction at all.
/// - **Stop pulling once [ended] completes.** Nothing sent after that arrives.
///   An endless producer — a chat, a sensor feed — is otherwise fed to a dead
///   call for as long as it runs, and on the responder side in silence, because
///   a send on a finished processor returns rather than throwing.
/// - **Route every failure away from the zone.** These callbacks are unawaited;
///   an unhandled async error in the root zone ends a server process.
/// - **Cancel without awaiting, and cancel BEFORE closing the controller.**
///   A producer parked in an `async*` never completes its cancellation, and
///   `StreamController.close()` throws while an `addStream` is still running.
final class SinkPump<T> {
  final String _what;
  final Future<void> Function(T item) _send;
  final Future<void> Function() _halfClose;
  final void Function(Object error, StackTrace stackTrace) _onSourceFailed;
  final LogScope _log;

  final StreamController<T> _controller = StreamController<T>();
  late final StreamSubscription<T> _subscription;
  bool _finished = false;

  /// Pumps into [send], naming itself [what] in the log.
  ///
  /// [halfClose] runs when the source ends normally; [onSourceFailed] when it
  /// errors, once, and it owns telling the peer. [ended] is the call's own
  /// end-of-life signal, whatever produced it.
  SinkPump({
    required String what,
    required Future<void> Function(T item) send,
    required Future<void> Function() halfClose,
    required void Function(Object error, StackTrace stackTrace) onSourceFailed,
    required Future<void> ended,
    LogScope? logger,
  }) : _what = what,
       _send = send,
       _halfClose = halfClose,
       _onSourceFailed = onSourceFailed,
       _log = logger ?? LogScope.noop {
    _subscription = _controller.stream.listen(
      (item) {
        if (_log.isInternal) {
          _log.internal('$_what: sending');
        }
        _subscription.pause();
        unawaited(
          _send(item)
              .catchError((Object error, StackTrace stackTrace) {
                _log.error(
                  '$_what: a send failed',
                  error: error,
                  stackTrace: stackTrace,
                );
              })
              .whenComplete(() {
                if (!_finished) _subscription.resume();
              }),
        );
      },
      onDone: () async {
        _finished = true;
        try {
          await _halfClose();
        } catch (error, stackTrace) {
          _log.error(
            '$_what: half-closing failed',
            error: error,
            stackTrace: stackTrace,
          );
        }
      },
      onError: (Object error, StackTrace stackTrace) {
        _log.error(
          '$_what: the source failed',
          error: error,
          stackTrace: stackTrace,
        );
        if (_finished) return;
        _finished = true;
        _onSourceFailed(error, stackTrace);
      },
    );

    unawaited(ended.then((_) => stop()).catchError((Object _) {}));
  }

  /// The sink to hand to the producer.
  StreamSink<T> get sink => _controller.sink;

  /// Whether the pump has stopped pulling.
  bool get isFinished => _finished;

  /// Stops pulling, without waiting for the source to unwind.
  void stop() {
    if (_finished) return;
    _finished = true;
    unawaited(_subscription.cancel().catchError((Object _) {}));
  }

  /// Owner teardown: stops pulling, then ends the sink.
  void close() {
    stop();
    if (!_controller.isClosed) {
      unawaited(_controller.close().catchError((Object _) {}));
    }
  }
}
