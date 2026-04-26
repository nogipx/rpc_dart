// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';
import 'dart:collection';

import 'package:rpc_dart/rpc_dart.dart';

/// gRPC status code for RESOURCE_EXHAUSTED (rate limit exceeded).
const int _statusResourceExhausted = 8;

/// Sliding-window rate-limiting interceptor.
///
/// Counts calls within a rolling time window and rejects excess calls with
/// a `RESOURCE_EXHAUSTED` [RpcException].
///
/// Usage:
/// ```dart
/// // Limit all methods to 100 calls per second
/// RpcRateLimiter.global(maxRequests: 100, window: Duration(seconds: 1))
///
/// // Per-method limits
/// RpcRateLimiter.perMethod({
///   'UserService.getUser':   (200, Duration(seconds: 1)),
///   'UserService.listUsers': (10,  Duration(seconds: 1)),
/// })
///
/// // Combined: global fallback + per-method overrides
/// RpcRateLimiter(
///   globalMax: 500,
///   globalWindow: Duration(seconds: 1),
///   methodLimits: {
///     'HeavyService.compute': (5, Duration(seconds: 1)),
///   },
/// )
/// ```
///
/// All limits are enforced within a single Dart isolate (single-threaded),
/// so no locks are needed.
class RpcRateLimiter extends IRpcInterceptor {
  final _SlidingWindowCounter? _global;
  final Map<String, _SlidingWindowCounter> _methodWindows;

  /// Creates a rate limiter that applies [maxRequests] per [window] globally.
  RpcRateLimiter.global({
    required int maxRequests,
    required Duration window,
  })  : _global = _SlidingWindowCounter(maxRequests: maxRequests, window: window),
        _methodWindows = const {};

  /// Creates a rate limiter with per-method limits.
  ///
  /// [limits] maps `"ServiceName.methodName"` to `(maxRequests, window)`.
  RpcRateLimiter.perMethod(
    Map<String, (int maxRequests, Duration window)> limits,
  )   : _global = null,
        _methodWindows = {
          for (final e in limits.entries)
            e.key: _SlidingWindowCounter(
              maxRequests: e.value.$1,
              window: e.value.$2,
            ),
        };

  /// Creates a rate limiter with an optional global fallback and per-method
  /// overrides.
  ///
  /// Per-method limits take priority over the global limit. Methods not
  /// listed in [methodLimits] fall back to the global limit (if set).
  RpcRateLimiter({
    int? globalMax,
    Duration? globalWindow,
    Map<String, (int maxRequests, Duration window)> methodLimits = const {},
  })  : _global = (globalMax != null && globalWindow != null)
            ? _SlidingWindowCounter(maxRequests: globalMax, window: globalWindow)
            : null,
        _methodWindows = {
          for (final e in methodLimits.entries)
            e.key: _SlidingWindowCounter(
              maxRequests: e.value.$1,
              window: e.value.$2,
            ),
        };

  void _checkLimit(String serviceName, String methodName) {
    final methodKey = '$serviceName.$methodName';
    final window = _methodWindows[methodKey] ?? _global;
    if (window == null) return;
    if (!window.tryAcquire()) {
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
    _checkLimit(call.serviceName, call.methodName);
    return next(call.context, request);
  }

  @override
  FutureOr<Stream<TResponse>> interceptServerStream<TRequest, TResponse>(
    RpcMiddlewareContext call,
    TRequest request,
    RpcServerStreamNext<TRequest, TResponse> next,
  ) async {
    _checkLimit(call.serviceName, call.methodName);
    return next(call.context, request);
  }

  @override
  Future<TResponse> interceptClientStream<TRequest, TResponse>(
    RpcMiddlewareContext call,
    Stream<TRequest> requests,
    RpcClientStreamNext<TRequest, TResponse> next,
  ) async {
    _checkLimit(call.serviceName, call.methodName);
    return next(call.context, requests);
  }

  @override
  FutureOr<Stream<TResponse>> interceptBidirectionalStream<TRequest, TResponse>(
    RpcMiddlewareContext call,
    Stream<TRequest> requests,
    RpcBidirectionalStreamNext<TRequest, TResponse> next,
  ) async {
    _checkLimit(call.serviceName, call.methodName);
    return next(call.context, requests);
  }
}

// ---------------------------------------------------------------------------
// Public exception type
// ---------------------------------------------------------------------------

/// Thrown by [RpcRateLimiter] when a call exceeds the configured limit.
///
/// Extends [RpcException] so the RPC core recognises it and returns a
/// meaningful error message to the caller. The gRPC status sent to the client
/// is `INTERNAL` (the core maps all [RpcException]s to it); extend the core's
/// error handling to map this to `RESOURCE_EXHAUSTED` if needed.
class RpcRateLimitException extends RpcException {
  RpcRateLimitException(super.message);
}

// ---------------------------------------------------------------------------
// Internal sliding-window counter
// ---------------------------------------------------------------------------

class _SlidingWindowCounter {
  final int maxRequests;
  final Duration window;
  final Queue<DateTime> _timestamps = Queue<DateTime>();

  _SlidingWindowCounter({required this.maxRequests, required this.window});

  /// Returns true and records a call if within the limit; false otherwise.
  bool tryAcquire() {
    final now = DateTime.now();
    final cutoff = now.subtract(window);
    // Evict timestamps that have fallen outside the window.
    while (_timestamps.isNotEmpty && _timestamps.first.isBefore(cutoff)) {
      _timestamps.removeFirst();
    }
    if (_timestamps.length >= maxRequests) return false;
    _timestamps.add(now);
    return true;
  }
}
