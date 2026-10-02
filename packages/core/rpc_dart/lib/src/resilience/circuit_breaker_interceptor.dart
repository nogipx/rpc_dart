// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';

import '../_internal.dart';

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
///
/// An [RpcStatusException] carrying UNAVAILABLE so it is findable by the one
/// `catch` that covers this library — untyped, it sat outside the hierarchy and
/// `catch (e) { if (e is RpcException) }` missed it entirely. UNAVAILABLE
/// because an open breaker is exactly "try again later", which is also what
/// `RpcRetryInterceptor` already treats as retryable.
class CircuitBreakerOpenException extends RpcStatusException {
  /// Time until the circuit breaker will transition to half-open.
  final Duration? retryAfter;

  /// Creates a [CircuitBreakerOpenException].
  ///
  /// Still `const`, which is why [retryAfter] is rendered in [toString] rather
  /// than folded into the status message: a const constructor cannot
  /// interpolate. `const CircuitBreakerOpenException()` is existing public API
  /// and appears twice in this file.
  const CircuitBreakerOpenException({this.retryAfter})
    : super(RpcStatus.unavailable, 'circuit is open');

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
  ///
  /// When null, [_isServerHealthFailure] applies: only statuses that say the
  /// SERVER is in trouble count. An application error is not a health signal — a
  /// server answering NOT_FOUND correctly is a working server — and state is per
  /// interceptor instance rather than per method, so counting one opens the
  /// breaker for every method on the endpoint.
  ///
  /// An explicit predicate fully replaces this.
  final bool Function(Object error)? failureOn;

  /// Statuses that mean the SERVER is unhealthy, not that the request was.
  ///
  /// Deliberately WIDER than `RpcRetryInterceptor`'s transient set, which is
  /// UNAVAILABLE and RESOURCE_EXHAUSTED: a breaker is asking "is this endpoint
  /// in trouble", where a retry asks "is another attempt worth making". INTERNAL
  /// and UNKNOWN are worth counting for the first question and not the second —
  /// they are what a crashing handler produces — and DEADLINE_EXCEEDED is the
  /// shape of a server too slow to answer at all.
  ///
  /// A non-RPC throw counts: an error with no status is not an application
  /// answering, it is something failing.
  static bool _isServerHealthFailure(Object error) {
    if (error is RpcCancelledException) return false;
    if (error is RpcStatusException) {
      return error.statusCode == RpcStatus.unavailable ||
          error.statusCode == RpcStatus.resourceExhausted ||
          error.statusCode == RpcStatus.internal ||
          error.statusCode == RpcStatus.unknown ||
          error.statusCode == RpcStatus.deadlineExceeded;
    }
    return true;
  }

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
    final admission = _checkState();

    try {
      final response = await next(call.context, request);
      _onSuccess(admission);
      return response;
    } catch (e) {
      _onFailure(admission, e);
      rethrow;
    }
  }

  @override
  FutureOr<Stream<TResponse>> interceptServerStream<TRequest, TResponse>(
    RpcMiddlewareContext call,
    TRequest request,
    RpcServerStreamNext<TRequest, TResponse> next,
  ) async {
    final _Admission admission;
    try {
      admission = _checkState();
    } on CircuitBreakerOpenException catch (e, st) {
      // Surface the open-circuit rejection through the stream so consumers
      // observe it the same way as an emitted stream error.
      return Stream<TResponse>.error(e, st);
    }

    try {
      final stream = await next(call.context, request);
      return _wrapStream(stream, admission);
    } catch (e) {
      _onFailure(admission, e);
      rethrow;
    }
  }

  @override
  Future<TResponse> interceptClientStream<TRequest, TResponse>(
    RpcMiddlewareContext call,
    Stream<TRequest> requests,
    RpcClientStreamNext<TRequest, TResponse> next,
  ) async {
    final admission = _checkState();

    try {
      final response = await next(call.context, requests);
      _onSuccess(admission);
      return response;
    } catch (e) {
      _onFailure(admission, e);
      rethrow;
    }
  }

  @override
  FutureOr<Stream<TResponse>> interceptBidirectionalStream<TRequest, TResponse>(
    RpcMiddlewareContext call,
    Stream<TRequest> requests,
    RpcBidirectionalStreamNext<TRequest, TResponse> next,
  ) async {
    final _Admission admission;
    try {
      admission = _checkState();
    } on CircuitBreakerOpenException catch (e, st) {
      return Stream<TResponse>.error(e, st);
    }

    try {
      final stream = await next(call.context, requests);
      return _wrapStream(stream, admission);
    } catch (e) {
      _onFailure(admission, e);
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
  Stream<TResponse> _wrapStream<TResponse>(
    Stream<TResponse> source,
    _Admission admitted,
  ) {
    var admission = admitted;
    var failed = false;
    var resolved = false;
    var listened = false;
    Timer? abandonTimer;

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
        _onSuccess(admission);
      }
      // Failures are recorded as they arrive (see handleError below) so the
      // count is exact; here we only release a pending success.
    }

    // The consumer walked away before the source terminated, so the probe
    // proved nothing either way. Free the gate without recording an outcome.
    void resolveInconclusive() {
      if (resolved) return;
      resolved = true;
      cancelAbandonTimer();
      _releaseProbe(admission);
    }

    // A PROBE stream proves recovery with its first message. Waiting for it to
    // end held the gate for the stream's whole life, and a subscription-style
    // stream -- a feed, a notification channel -- never ends: every other call
    // on the endpoint was rejected for as long as it ran. From the first
    // message on, the stream is an ordinary call of the closed breaker.
    final observed = !admission.isProbe
        ? source
        : source.transform(
            StreamTransformer<TResponse, TResponse>.fromHandlers(
              handleData: (data, sink) {
                if (admission.isProbe) {
                  _onSuccess(admission);
                  admission = _Admission(_generation, isProbe: false);
                }
                sink.add(data);
              },
            ),
          );

    final bridge = StreamBridge<TResponse>(
      source: observed,
      onFirstListen: () {
        listened = true;
        // Stream is being consumed; the abandon safety net is no longer needed.
        cancelAbandonTimer();
      },
      onSourceError: (Object error, StackTrace stackTrace) {
        failed = true;
        // Count the failure immediately so the breaker reopens even if the
        // wrapped stream is never listened.
        _onFailure(admission, error);
        resolve(success: false);
      },
      onSourceDone: () {
        if (!failed) resolve(success: true);
      },
      // Downstream cancelled before the source terminated. A cancelled
      // subscription never delivers onDone, and onListen already cancelled the
      // abandon timer, so without this the gate stays pinned and the breaker
      // rejects every later call forever. Reached after a normal close too,
      // where `resolved` makes it a no-op.
      onConsumerCancel: resolveInconclusive,
    );

    // If the stream is never listened and the source never completes, release
    // the probe after a safety window so the breaker cannot stay stuck.
    abandonTimer = Timer(probeAbandonTimeout, () {
      if (resolved || listened) return;
      // INCONCLUSIVE, not a success. Nobody observed this probe, so it is not
      // evidence that the peer recovered -- and recording a success CLOSES the
      // breaker on a result the code invented. The gate is released either way,
      // so the breaker cannot stay wedged; it stays half-open and the next call
      // takes its turn as the probe, which is a real observation.
      resolveInconclusive();
      // Drop the dangling source subscription; nothing consumes it. Ended
      // with an error rather than left open: a caller arriving later waited on
      // a stream that never ended, and an empty one would read as success.
      bridge.fail(
        RpcCancelledException(
          'Stream abandoned: not listened to within $probeAbandonTimeout',
        ),
      );
    });

    return bridge.stream;
  }

  /// Bumped on every state change. An outcome counts only against the
  /// generation its call was admitted in; see [_Admission].
  int _generation = 0;

  void _setState(CircuitBreakerState state) {
    _state = state;
    _generation++;
  }

  /// Admits a call, or throws [CircuitBreakerOpenException] if the circuit is
  /// open, and says what the call was admitted as.
  _Admission _checkState() {
    switch (_state) {
      case CircuitBreakerState.closed:
        return _Admission(_generation, isProbe: false);

      case CircuitBreakerState.open:
        // Check if reset timeout has elapsed (monotonic, clock-jump immune).
        if (_sinceLastFailure != null) {
          final elapsed = _sinceLastFailure!.elapsed;
          if (elapsed >= resetTimeout) {
            // Transition to half-open and admit exactly this one probe.
            _setState(CircuitBreakerState.halfOpen);
            _probeInFlight = true;
            return _Admission(_generation, isProbe: true);
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
        return _Admission(_generation, isProbe: true);
    }
  }

  /// Releases the single-probe gate without recording an outcome, leaving the
  /// breaker half-open so the next call takes its turn as the probe. For
  /// outcomes that say nothing about recovery: a cancellation, an error the
  /// [failureOn] predicate rejects, a consumer that cancelled a stream probe.
  ///
  /// Only the probe's own: a call admitted earlier, while the breaker was
  /// closed, freed the gate while the real probe was still running and let a
  /// second one in.
  void _releaseProbe(_Admission admission) {
    if (admission.isProbe && admission.generation == _generation) {
      _probeInFlight = false;
    }
  }

  void _onSuccess(_Admission admission) {
    // Stale: the call was admitted before the breaker last changed state. A
    // call that began while the breaker was closed and succeeded after it
    // opened proves nothing about recovery -- and in half-open it used to be
    // taken for the probe's result and CLOSE the breaker while the real probe
    // was still in flight.
    if (admission.generation != _generation) return;
    _failureCount = 0;
    if (admission.isProbe) {
      // The admitted probe succeeded — close the circuit and clear the gate.
      _probeInFlight = false;
      _setState(CircuitBreakerState.closed);
    }
  }

  void _onFailure(_Admission admission, Object error) {
    // Don't count cancellations as failures, nor anything the predicate rejects.
    // The default predicate excludes cancellation itself, and an explicit one is
    // still guarded against it: a caller's own predicate should not have to know
    // that a cancelled call is not evidence about the server.
    final counts =
        error is! RpcCancelledException &&
        (failureOn ?? _isServerHealthFailure)(error);

    if (!counts) {
      // Inconclusive: it says nothing about whether the service recovered. The
      // gate must still be released, or an ordinary cancellation (deadline,
      // caller navigated away) pins the breaker half-open forever.
      _releaseProbe(admission);
      return;
    }

    // Stale, as in [_onSuccess]. A failure from before the breaker opened
    // reopened it from half-open and restarted the timer, so the real probe's
    // success then landed in OPEN and was dropped.
    if (admission.generation != _generation) return;

    _failureCount++;
    // Restart the monotonic timer from this failure.
    (_sinceLastFailure ??= Stopwatch())
      ..reset()
      ..start();

    if (admission.isProbe) {
      // Probe failed — reopen and release the probe gate.
      _probeInFlight = false;
      _setState(CircuitBreakerState.open);
    } else if (_failureCount >= failureThreshold) {
      _setState(CircuitBreakerState.open);
    }
  }

  /// Manually resets the circuit breaker to closed state.
  void reset() {
    _setState(CircuitBreakerState.closed);
    _failureCount = 0;
    _sinceLastFailure?.stop();
    _sinceLastFailure = null;
    _probeInFlight = false;
  }
}

/// What one call was admitted as: the probe or an ordinary call, and in which
/// generation of the breaker's state. Its outcome is judged against that, not
/// against whatever state the breaker is in when the call ends.
final class _Admission {
  _Admission(this.generation, {required this.isProbe});

  final int generation;
  final bool isProbe;
}
