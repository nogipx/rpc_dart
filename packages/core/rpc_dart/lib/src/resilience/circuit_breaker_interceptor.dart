// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';

/// Circuit breaker states.
enum CircuitBreakerState {
  /// Normal operation. Requests pass through.
  closed,

  /// Circuit tripped. Requests fail immediately without calling the service.
  open,

  /// Probing. One request is allowed through to test recovery.
  halfOpen,
}

/// Exception thrown when the circuit breaker is open.
class CircuitBreakerOpenException implements Exception {
  /// Time until the circuit breaker will transition to half-open.
  final Duration? retryAfter;

  /// Creates a [CircuitBreakerOpenException].
  const CircuitBreakerOpenException({this.retryAfter});

  @override
  String toString() {
    if (retryAfter != null) {
      return 'CircuitBreakerOpenException: circuit is open, retry after ${retryAfter!.inMilliseconds}ms';
    }
    return 'CircuitBreakerOpenException: circuit is open';
  }
}

/// Interceptor that implements the circuit breaker pattern.
///
/// Tracks consecutive failures. When failures exceed [failureThreshold],
/// the circuit opens and subsequent calls fail immediately with
/// [CircuitBreakerOpenException]. After [resetTimeout], one probe request
/// is allowed through (half-open). If it succeeds, the circuit closes.
/// If it fails, the circuit opens again.
///
/// Usage:
/// ```dart
/// caller.addInterceptor(RpcCircuitBreakerInterceptor(
///   failureThreshold: 5,
///   resetTimeout: Duration(seconds: 30),
/// ));
/// ```
class RpcCircuitBreakerInterceptor extends IRpcInterceptor {
  /// Number of consecutive failures before the circuit opens.
  final int failureThreshold;

  /// How long the circuit stays open before transitioning to half-open.
  final Duration resetTimeout;

  /// Optional predicate to decide if an error counts as a failure.
  /// Defaults to counting all errors except cancellation.
  final bool Function(Object error)? failureOn;

  CircuitBreakerState _state = CircuitBreakerState.closed;
  int _failureCount = 0;

  /// Monotonic stopwatch measuring elapsed time since the last recorded
  /// failure. A [Stopwatch] is immune to wall-clock jumps (NTP corrections,
  /// manual clock changes) that would make a `DateTime.now()` subtraction go
  /// negative or huge and either pin the breaker open forever or half-open it
  /// instantly. Null while no failure has been recorded yet.
  Stopwatch? _sinceLastFailure;

  /// Whether a half-open probe is currently in flight. Only one probe is
  /// admitted in [CircuitBreakerState.halfOpen]; further calls are rejected
  /// until the in-flight probe resolves (success -> close, failure -> reopen).
  bool _probeInFlight = false;

  /// Safety window after which an admitted half-open probe whose wrapped stream
  /// is never listened (the caller abandoned it) is force-released so the
  /// breaker does not stay stuck in half-open forever.
  final Duration probeAbandonTimeout;

  /// Creates a circuit breaker interceptor.
  RpcCircuitBreakerInterceptor({
    this.failureThreshold = 5,
    this.resetTimeout = const Duration(seconds: 30),
    this.failureOn,
    this.probeAbandonTimeout = const Duration(seconds: 30),
  });

  /// Current state of the circuit breaker.
  CircuitBreakerState get state => _state;

  /// Current consecutive failure count.
  int get failureCount => _failureCount;

  @override
  Future<TResponse> interceptUnary<TRequest, TResponse>(
    RpcMiddlewareContext call,
    TRequest request,
    RpcUnaryNext<TRequest, TResponse> next,
  ) async {
    _checkState();

    try {
      final response = await next(call.context, request);
      _onSuccess();
      return response;
    } catch (e) {
      _onFailure(e);
      rethrow;
    }
  }

  @override
  FutureOr<Stream<TResponse>> interceptServerStream<TRequest, TResponse>(
    RpcMiddlewareContext call,
    TRequest request,
    RpcServerStreamNext<TRequest, TResponse> next,
  ) async {
    try {
      _checkState();
    } on CircuitBreakerOpenException catch (e, st) {
      // Surface the open-circuit rejection through the stream so consumers
      // observe it the same way as an emitted stream error.
      return Stream<TResponse>.error(e, st);
    }

    try {
      final stream = await next(call.context, request);
      return _wrapStream(stream);
    } catch (e) {
      _onFailure(e);
      rethrow;
    }
  }

  @override
  Future<TResponse> interceptClientStream<TRequest, TResponse>(
    RpcMiddlewareContext call,
    Stream<TRequest> requests,
    RpcClientStreamNext<TRequest, TResponse> next,
  ) async {
    _checkState();

    try {
      final response = await next(call.context, requests);
      _onSuccess();
      return response;
    } catch (e) {
      _onFailure(e);
      rethrow;
    }
  }

  @override
  FutureOr<Stream<TResponse>> interceptBidirectionalStream<TRequest, TResponse>(
    RpcMiddlewareContext call,
    Stream<TRequest> requests,
    RpcBidirectionalStreamNext<TRequest, TResponse> next,
  ) async {
    try {
      _checkState();
    } on CircuitBreakerOpenException catch (e, st) {
      return Stream<TResponse>.error(e, st);
    }

    try {
      final stream = await next(call.context, requests);
      return _wrapStream(stream);
    } catch (e) {
      _onFailure(e);
      rethrow;
    }
  }

  /// Wraps a returned stream so that failures emitted during stream production
  /// are counted, and success is only recorded on clean completion.
  ///
  /// Since [next] returns the stream synchronously (before any item flows),
  /// recording success eagerly would let stream errors bypass the breaker.
  ///
  /// The source is subscribed to EAGERLY (independent of whether the returned
  /// stream is ever listened) so the half-open probe gate is always released:
  /// `_onSuccess`/`_onFailure` fire when the source terminates even if the
  /// caller obtains the wrapped stream but abandons it. Without this, an
  /// abandoned probe would pin `_probeInFlight = true` and the breaker would
  /// reject every subsequent call forever. A safety timer additionally releases
  /// the probe if the source never terminates and the stream is never listened.
  Stream<TResponse> _wrapStream<TResponse>(Stream<TResponse> source) {
    var failed = false;
    var resolved = false;
    var listened = false;
    Timer? abandonTimer;
    late StreamSubscription<TResponse> sub;
    late StreamController<TResponse> controller;

    void cancelAbandonTimer() {
      abandonTimer?.cancel();
      abandonTimer = null;
    }

    // Records the breaker outcome at most once for this stream's lifetime.
    void resolve({required bool success}) {
      if (resolved) return;
      resolved = true;
      cancelAbandonTimer();
      if (success) {
        _onSuccess();
      }
      // Failures are recorded as they arrive (see handleError below) so the
      // count is exact; here we only release a pending success.
    }

    controller = StreamController<TResponse>(
      onListen: () {
        listened = true;
        // Stream is being consumed; the abandon safety net is no longer needed.
        cancelAbandonTimer();
      },
      onPause: () => sub.pause(),
      onResume: () => sub.resume(),
      onCancel: () async {
        // Downstream cancelled: stop pulling from the source. The probe gate
        // is released by source termination or the abandon timer, not here.
        await sub.cancel();
      },
    );

    sub = source.listen(
      (data) {
        if (!controller.isClosed) controller.add(data);
      },
      onError: (Object error, StackTrace stackTrace) {
        failed = true;
        // Count the failure immediately so the breaker reopens even if the
        // wrapped stream is never listened.
        _onFailure(error);
        resolve(success: false);
        if (!controller.isClosed) controller.addError(error, stackTrace);
      },
      onDone: () {
        if (!failed) resolve(success: true);
        if (!controller.isClosed) controller.close();
      },
    );

    // If the stream is never listened and the source never completes, release
    // the probe after a safety window so the breaker cannot stay stuck.
    abandonTimer = Timer(probeAbandonTimeout, () {
      if (resolved || listened) return;
      // Treat an abandoned, never-completing probe as a success so the breaker
      // can recover (close) rather than remaining wedged in half-open.
      resolve(success: true);
      // Drop the dangling source subscription; nothing consumes it.
      sub.cancel();
    });

    return controller.stream;
  }

  /// Checks whether a request is allowed based on the current state.
  /// Throws [CircuitBreakerOpenException] if the circuit is open.
  void _checkState() {
    switch (_state) {
      case CircuitBreakerState.closed:
        return; // Allow through.

      case CircuitBreakerState.open:
        // Check if reset timeout has elapsed (monotonic, clock-jump immune).
        if (_sinceLastFailure != null) {
          final elapsed = _sinceLastFailure!.elapsed;
          if (elapsed >= resetTimeout) {
            // Transition to half-open and admit exactly this one probe.
            _state = CircuitBreakerState.halfOpen;
            _probeInFlight = true;
            return;
          }
          throw CircuitBreakerOpenException(retryAfter: resetTimeout - elapsed);
        }
        throw const CircuitBreakerOpenException();

      case CircuitBreakerState.halfOpen:
        // Single-probe gate: only one probe may run at a time. Reject the
        // rest until the in-flight probe resolves (success or failure).
        if (_probeInFlight) {
          throw const CircuitBreakerOpenException();
        }
        _probeInFlight = true;
        return;
    }
  }

  void _onSuccess() {
    switch (_state) {
      case CircuitBreakerState.halfOpen:
        // The admitted probe succeeded — close the circuit and clear the gate.
        _failureCount = 0;
        _probeInFlight = false;
        _state = CircuitBreakerState.closed;
      case CircuitBreakerState.closed:
        // Normal success breaks the consecutive-failure streak.
        _failureCount = 0;
      case CircuitBreakerState.open:
        // Stale success: this call began (and passed _checkState) while the
        // breaker was still closed, then completed after other concurrent
        // failures opened it. It proves nothing about recovery, so it must NOT
        // re-close the breaker — only a half-open probe may do that.
        break;
    }
  }

  void _onFailure(Object error) {
    // Don't count cancellations as failures, nor anything failureOn rejects.
    final counts =
        error is! RpcCancelledException &&
        (failureOn == null || failureOn!(error));

    if (!counts) {
      // The outcome is inconclusive — it says nothing about whether the
      // service recovered. But if this call was the admitted half-open probe,
      // the gate MUST still be released: returning early left _probeInFlight
      // pinned true with the state stuck at halfOpen, so every later call was
      // rejected with CircuitBreakerOpenException forever, with nothing but a
      // manual reset() to clear it. A cancelled probe is ordinary (deadline,
      // caller navigated away), so this wedged real clients. Stay half-open
      // and let the next call take its turn as the probe.
      if (_state == CircuitBreakerState.halfOpen) _probeInFlight = false;
      return;
    }

    _failureCount++;
    // Restart the monotonic timer from this failure.
    (_sinceLastFailure ??= Stopwatch())
      ..reset()
      ..start();

    if (_state == CircuitBreakerState.halfOpen) {
      // Probe failed — reopen and release the probe gate.
      _probeInFlight = false;
      _state = CircuitBreakerState.open;
    } else if (_failureCount >= failureThreshold) {
      _state = CircuitBreakerState.open;
    }
  }

  /// Manually resets the circuit breaker to closed state.
  void reset() {
    _state = CircuitBreakerState.closed;
    _failureCount = 0;
    _sinceLastFailure?.stop();
    _sinceLastFailure = null;
    _probeInFlight = false;
  }
}
