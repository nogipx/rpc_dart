// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';

/// gRPC status code for RESOURCE_EXHAUSTED (rate limit exceeded).
const int _statusResourceExhausted = 8;

// ---------------------------------------------------------------------------
// Public rate-limit algorithm descriptors
// ---------------------------------------------------------------------------

/// A stateful rate-limit counter.
///
/// Create one instance per slot (global / per-service / per-method) and pass
/// it to [RpcRateLimiter]. Each call to [tryAcquire] either allows the
/// request (returns `true`) or rejects it (returns `false`).
///
/// Two built-in algorithms:
///
/// - [RateLimit.slidingWindow] — O(1) sliding-window counter using two
///   fixed-window buckets. Strict: no burst allowance.
/// - [RateLimit.tokenBucket] — token-bucket with configurable burst capacity.
///   Allows short bursts above the average rate.
sealed class RateLimit {
  const RateLimit();

  /// O(1) sliding-window counter.
  ///
  /// Approximates a true sliding window using two adjacent fixed-window
  /// buckets. Weighted estimate:
  ///   `count ≈ current + previous × (1 − elapsed/window)`
  ///
  /// [max] requests are allowed per [window]. No burst above [max].
  factory RateLimit.slidingWindow({
    required int max,
    required Duration window,
  }) = _SlidingWindowCounter;

  /// Token-bucket counter.
  ///
  /// Tokens refill at [max] per [window]. The bucket holds at most
  /// [burst] tokens (defaults to [max], i.e. no extra burst). Short
  /// spikes up to [burst] requests are served instantly as long as the
  /// bucket is sufficiently full.
  factory RateLimit.tokenBucket({
    required int max,
    required Duration window,
    int? burst,
  }) = _TokenBucketCounter;

  /// Attempts to acquire one request slot.
  ///
  /// Returns `true` if the request is within the limit, `false` otherwise.
  bool tryAcquire();
}

// ---------------------------------------------------------------------------
// Sliding-window counter (O(1))
// ---------------------------------------------------------------------------

class _SlidingWindowCounter implements RateLimit {
  final int max;
  final int _windowUs;

  int _current = 0;
  int _previous = 0;
  int _windowStartUs;

  _SlidingWindowCounter({required this.max, required Duration window})
      : _windowUs = window.inMicroseconds,
        _windowStartUs = DateTime.now().microsecondsSinceEpoch;

  @override
  bool tryAcquire() {
    final nowUs = DateTime.now().microsecondsSinceEpoch;
    final elapsedUs = nowUs - _windowStartUs;

    if (elapsedUs >= _windowUs) {
      final periods = elapsedUs ~/ _windowUs;
      _previous = periods >= 2 ? 0 : _current;
      _current = 0;
      _windowStartUs += periods * _windowUs;
    }

    final elapsedInCurrentUs = nowUs - _windowStartUs;
    final weight = 1.0 - (elapsedInCurrentUs / _windowUs);
    final estimated = _current + (_previous * weight).floor();

    if (estimated >= max) return false;
    _current++;
    return true;
  }
}

// ---------------------------------------------------------------------------
// Token-bucket counter
// ---------------------------------------------------------------------------

class _TokenBucketCounter implements RateLimit {
  final int max;
  final int burst;
  final int _windowUs;

  double _tokens;
  int _lastRefillUs;

  _TokenBucketCounter({required this.max, required Duration window, int? burst})
      : burst = burst ?? max,
        _windowUs = window.inMicroseconds,
        _tokens = (burst ?? max).toDouble(),
        _lastRefillUs = DateTime.now().microsecondsSinceEpoch;

  @override
  bool tryAcquire() {
    final nowUs = DateTime.now().microsecondsSinceEpoch;
    final elapsedUs = nowUs - _lastRefillUs;

    final refill = (elapsedUs / _windowUs) * max;
    _tokens = (_tokens + refill).clamp(0.0, burst.toDouble());
    _lastRefillUs = nowUs;

    if (_tokens < 1.0) return false;
    _tokens -= 1.0;
    return true;
  }
}

// ---------------------------------------------------------------------------
// Interceptor
// ---------------------------------------------------------------------------

/// Rate-limiting interceptor for [RpcResponderEndpoint].
///
/// Attach a [RateLimit] counter to the global scope, individual services, or
/// individual methods. Priority: `perMethod` > `perService` > `global`.
///
/// ```dart
/// // Single global limit using the sliding-window algorithm
/// RpcRateLimiter(
///   global: RateLimit.slidingWindow(max: 500, window: Duration(seconds: 1)),
/// )
///
/// // Per-service and per-method with different algorithms
/// RpcRateLimiter(
///   global: RateLimit.slidingWindow(max: 1000, window: Duration(seconds: 1)),
///   perService: {
///     'HeavyService': RateLimit.slidingWindow(max: 10, window: Duration(seconds: 1)),
///   },
///   perMethod: {
///     'UserService.getUser': RateLimit.tokenBucket(
///       max: 200, window: Duration(seconds: 1), burst: 300,
///     ),
///   },
/// )
/// ```
///
/// All limits are enforced within a single Dart isolate (no locks needed).
class RpcRateLimiter extends IRpcInterceptor {
  final RateLimit? _global;
  final Map<String, RateLimit> _perService;
  final Map<String, RateLimit> _perMethod;

  /// Creates a rate limiter.
  ///
  /// [global] — fallback limit for any method not matched by [perService] or
  /// [perMethod].
  ///
  /// [perService] — maps a service name (e.g. `'UserService'`) to a limit
  /// applied to all its methods.
  ///
  /// [perMethod] — maps `'ServiceName.methodName'` to a limit applied to that
  /// specific method. Takes priority over [perService] and [global].
  const RpcRateLimiter({
    RateLimit? global,
    Map<String, RateLimit> perService = const {},
    Map<String, RateLimit> perMethod = const {},
  })  : _global = global,
        _perService = perService,
        _perMethod = perMethod;

  void _check(String serviceName, String methodName) {
    final methodKey = '$serviceName.$methodName';
    final counter = _perMethod[methodKey] ?? _perService[serviceName] ?? _global;
    if (counter == null) return;
    if (!counter.tryAcquire()) {
      throw RpcRateLimitException(
        'Rate limit exceeded for $methodKey '
        '(gRPC status $_statusResourceExhausted: RESOURCE_EXHAUSTED)',
      );
    }
  }

  @override
  Future<TResponse> interceptUnary<TRequest, TResponse>(
    RpcMiddlewareContext call,
    TRequest request,
    RpcUnaryNext<TRequest, TResponse> next,
  ) async {
    _check(call.serviceName, call.methodName);
    return next(call.context, request);
  }

  @override
  FutureOr<Stream<TResponse>> interceptServerStream<TRequest, TResponse>(
    RpcMiddlewareContext call,
    TRequest request,
    RpcServerStreamNext<TRequest, TResponse> next,
  ) async {
    _check(call.serviceName, call.methodName);
    return next(call.context, request);
  }

  @override
  Future<TResponse> interceptClientStream<TRequest, TResponse>(
    RpcMiddlewareContext call,
    Stream<TRequest> requests,
    RpcClientStreamNext<TRequest, TResponse> next,
  ) async {
    _check(call.serviceName, call.methodName);
    return next(call.context, requests);
  }

  @override
  FutureOr<Stream<TResponse>> interceptBidirectionalStream<TRequest, TResponse>(
    RpcMiddlewareContext call,
    Stream<TRequest> requests,
    RpcBidirectionalStreamNext<TRequest, TResponse> next,
  ) async {
    _check(call.serviceName, call.methodName);
    return next(call.context, requests);
  }
}

// ---------------------------------------------------------------------------
// Public exception type
// ---------------------------------------------------------------------------

/// Thrown by [RpcRateLimiter] when a call exceeds the configured limit.
class RpcRateLimitException extends RpcException {
  RpcRateLimitException(super.message);
}
