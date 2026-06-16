// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';

/// gRPC status code for RESOURCE_EXHAUSTED (rate limit exceeded).
const int _statusResourceExhausted = 8;

// ---------------------------------------------------------------------------
// Public rate-limit algorithm spec
// ---------------------------------------------------------------------------

/// Describes a rate-limit algorithm and its parameters.
///
/// A [RateLimit] instance is a **specification** — it is passed to
/// [RpcRateLimiter] which creates internal counters from it as needed.
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
  /// [max] requests are allowed per [window]. No burst above [max].
  const factory RateLimit.slidingWindow({
    required int max,
    required Duration window,
  }) = _SlidingWindowSpec;

  /// Token-bucket counter.
  ///
  /// Tokens refill at [max] per [window]. The bucket holds at most [burst]
  /// tokens (defaults to [max]). Short spikes up to [burst] are served
  /// instantly as long as the bucket is sufficiently full.
  const factory RateLimit.tokenBucket({
    required int max,
    required Duration window,
    int? burst,
  }) = _TokenBucketSpec;

  /// Creates a fresh stateful counter for this spec.
  ///
  /// [nowMicros] supplies the current time in microseconds; injecting it makes
  /// timing testable and immune to wall-clock jumps.
  _RateLimitCounter _createCounter(int Function() nowMicros);

  /// The window duration of this spec (used for stale-entry cleanup).
  Duration get _window;
}

// ---------------------------------------------------------------------------
// Spec implementations
// ---------------------------------------------------------------------------

class _SlidingWindowSpec extends RateLimit {
  final int max;
  @override
  final Duration _window;

  const _SlidingWindowSpec({required this.max, required Duration window})
      : _window = window;

  @override
  _RateLimitCounter _createCounter(int Function() nowMicros) =>
      _SlidingWindowCounter(max: max, window: _window, nowMicros: nowMicros);
}

class _TokenBucketSpec extends RateLimit {
  final int max;
  final int? burst;
  @override
  final Duration _window;

  const _TokenBucketSpec(
      {required this.max, required Duration window, this.burst})
      : _window = window;

  @override
  _RateLimitCounter _createCounter(int Function() nowMicros) =>
      _TokenBucketCounter(
          max: max, window: _window, burst: burst ?? max, nowMicros: nowMicros);
}

// ---------------------------------------------------------------------------
// Internal counter base
// ---------------------------------------------------------------------------

abstract class _RateLimitCounter {
  _RateLimitCounter(this._nowMicros)
      : _lastUsedUs = _nowMicros();

  /// Injected monotonic-friendly clock (microseconds).
  final int Function() _nowMicros;

  int _lastUsedUs;

  /// Attempts to acquire one request slot.
  bool tryAcquire() {
    _lastUsedUs = _nowMicros();
    return _doAcquire();
  }

  bool _doAcquire();
}

// ---------------------------------------------------------------------------
// Sliding-window counter (O(1))
// ---------------------------------------------------------------------------

class _SlidingWindowCounter extends _RateLimitCounter {
  final int max;
  final int _windowUs;

  int _current = 0;
  int _previous = 0;
  int _windowStartUs;

  _SlidingWindowCounter(
      {required this.max,
      required Duration window,
      required int Function() nowMicros})
      : _windowUs = window.inMicroseconds,
        _windowStartUs = nowMicros(),
        super(nowMicros);

  @override
  bool _doAcquire() {
    final nowUs = _nowMicros();
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

class _TokenBucketCounter extends _RateLimitCounter {
  final int max;
  final int burst;
  final int _windowUs;

  double _tokens;
  int _lastRefillUs;

  _TokenBucketCounter(
      {required this.max,
      required Duration window,
      required this.burst,
      required int Function() nowMicros})
      : _windowUs = window.inMicroseconds,
        _tokens = burst.toDouble(),
        _lastRefillUs = nowMicros(),
        super(nowMicros);

  @override
  bool _doAcquire() {
    final nowUs = _nowMicros();
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
/// ## Static limits (no [keyExtractor])
///
/// One shared counter per slot — same limit for all callers:
///
/// ```dart
/// RpcRateLimiter(
///   global: RateLimit.slidingWindow(max: 1000, window: Duration(seconds: 1)),
///   perService: {'HeavyService': RateLimit.slidingWindow(max: 10, window: Duration(seconds: 1))},
///   perMethod: {'UserService.search': RateLimit.tokenBucket(max: 5, window: Duration(seconds: 1))},
/// )
/// ```
///
/// ## Per-key limits ([keyExtractor] provided)
///
/// Each unique key extracted from the call context gets **independent counters**
/// for [perService] and [perMethod] slots. Typical use: isolate users so one
/// caller cannot exhaust the limit for others.
///
/// [global] is always a single shared counter regardless of [keyExtractor].
///
/// ```dart
/// RpcRateLimiter(
///   global: RateLimit.slidingWindow(max: 5000, window: Duration(seconds: 1)),
///   perMethod: {
///     'SyncService.push': RateLimit.tokenBucket(max: 10, window: Duration(seconds: 1), burst: 20),
///   },
///   keyExtractor: (ctx) => ctx.context.getValue<String>('userId'),
/// )
/// ```
///
/// ## Per-key fallback ([perKeyFallback])
///
/// A catch-all limit applied per `(key, method)` when no [perMethod] or
/// [perService] spec matches. Equivalent to listing every method in [perMethod]
/// with the same spec, but without explicit enumeration.
///
/// ```dart
/// RpcRateLimiter(
///   global: RateLimit.slidingWindow(max: 5000, window: Duration(seconds: 1)),
///   perKeyFallback: RateLimit.slidingWindow(max: 50, window: Duration(seconds: 1)),
///   keyExtractor: (call) =>
///       call.context.getValue<String>('userId') ??
///       'anon:${call.endpoint.hashCode}',
/// )
/// ```
///
/// If [keyExtractor] returns `null` for a call, dynamic limits are skipped and
/// only [global] applies.
///
/// Call [dispose] when the endpoint shuts down to cancel the cleanup timer.
///
/// ## Priority
///
/// `perMethod[key]` > `perService[key]` > `perKeyFallback[key:method]` > `global`
///
/// All limits are enforced within a single Dart isolate (no locks needed).
class RpcRateLimiter extends IRpcInterceptor {
  /// Creates a rate limiter.
  ///
  /// When [keyExtractor] is provided, [perService] and [perMethod] counters
  /// are created dynamically per extracted key. [global] is always shared.
  ///
  /// [cleanupInterval] controls how often stale per-key counters are evicted
  /// (only relevant when [keyExtractor] is set).
  ///
  /// [nowMicros] supplies the current time in microseconds. It defaults to a
  /// monotonic source (a process-wide [Stopwatch]) so timing cannot be broken
  /// by wall-clock jumps and is testable. Pass a custom function to inject a
  /// fake clock in tests.
  RpcRateLimiter({
    RateLimit? global,
    Map<String, RateLimit> perService = const {},
    Map<String, RateLimit> perMethod = const {},
    RateLimit? perKeyFallback,
    String? Function(RpcMiddlewareContext)? keyExtractor,
    Duration cleanupInterval = const Duration(minutes: 5),
    int Function()? nowMicros,
  })  : _globalSpec = global,
        _perServiceSpec = Map.unmodifiable(perService),
        _perMethodSpec = Map.unmodifiable(perMethod),
        _perKeyFallbackSpec = perKeyFallback,
        _keyExtractor = keyExtractor,
        _nowMicros = nowMicros ?? _defaultMonotonicMicros {
    _globalCounter = global?._createCounter(_nowMicros);

    if (keyExtractor == null) {
      // Static mode: create one counter per slot up front.
      _staticServiceCounters = {
        for (final e in perService.entries)
          e.key: e.value._createCounter(_nowMicros),
      };
      _staticMethodCounters = {
        for (final e in perMethod.entries)
          e.key: e.value._createCounter(_nowMicros),
      };
    } else {
      _staticServiceCounters = const {};
      _staticMethodCounters = const {};
      _cleanupTimer = Timer.periodic(cleanupInterval, (_) => _cleanup());
    }
  }

  /// Process-wide monotonic clock, immune to wall-clock jumps.
  static final Stopwatch _monotonic = Stopwatch()..start();
  static int _defaultMonotonicMicros() => _monotonic.elapsedMicroseconds;

  final RateLimit? _globalSpec;
  final Map<String, RateLimit> _perServiceSpec;
  final Map<String, RateLimit> _perMethodSpec;
  final RateLimit? _perKeyFallbackSpec;
  final String? Function(RpcMiddlewareContext)? _keyExtractor;
  final int Function() _nowMicros;
  bool _disposed = false;

  _RateLimitCounter? _globalCounter;
  late final Map<String, _RateLimitCounter> _staticServiceCounters;
  late final Map<String, _RateLimitCounter> _staticMethodCounters;

  // Dynamic counters: userKey -> slotKey -> counter
  final Map<String, Map<String, _RateLimitCounter>> _dynamicServiceCounters =
      {};
  final Map<String, Map<String, _RateLimitCounter>> _dynamicMethodCounters = {};
  final Map<String, Map<String, _RateLimitCounter>> _dynamicFallbackCounters =
      {};

  Timer? _cleanupTimer;

  /// Cancels the cleanup timer and releases dynamic counter state.
  ///
  /// After disposal the limiter no longer enforces or creates counters; calls
  /// to [_check] become no-ops so the cleared maps cannot be repopulated while
  /// the cleanup timer is cancelled (which would otherwise grow unbounded).
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _cleanupTimer?.cancel();
    _dynamicServiceCounters.clear();
    _dynamicMethodCounters.clear();
    _dynamicFallbackCounters.clear();
  }

  void _cleanup() {
    final nowUs = _nowMicros();
    final thresholdUs = _maxWindowUs() * 2;

    void evict(Map<String, Map<String, _RateLimitCounter>> store) {
      store.removeWhere((_, slots) {
        slots.removeWhere((_, c) => (nowUs - c._lastUsedUs) > thresholdUs);
        return slots.isEmpty;
      });
    }

    evict(_dynamicServiceCounters);
    evict(_dynamicMethodCounters);
    evict(_dynamicFallbackCounters);
  }

  int _maxWindowUs() {
    var max = 0;
    for (final spec in [
      _globalSpec,
      _perKeyFallbackSpec,
      ..._perServiceSpec.values,
      ..._perMethodSpec.values,
    ]) {
      if (spec == null) continue;
      final w = spec._window.inMicroseconds;
      if (w > max) max = w;
    }
    return max;
  }

  _RateLimitCounter? _getDynamic(
    Map<String, Map<String, _RateLimitCounter>> store,
    String userKey,
    String slotKey,
    RateLimit? spec,
  ) {
    if (spec == null) return null;
    return store
        .putIfAbsent(userKey, () => {})
        .putIfAbsent(slotKey, () => spec._createCounter(_nowMicros));
  }

  void _check(RpcMiddlewareContext call) {
    // After dispose the cleanup timer is cancelled; creating new dynamic
    // counters here would grow unbounded. No-op instead.
    if (_disposed) return;

    final methodKey = '${call.serviceName}.${call.methodName}';
    final userKey = _keyExtractor?.call(call);

    final _RateLimitCounter? counter;

    if (userKey != null) {
      counter = _getDynamic(_dynamicMethodCounters, userKey, methodKey,
              _perMethodSpec[methodKey]) ??
          _getDynamic(_dynamicServiceCounters, userKey, call.serviceName,
              _perServiceSpec[call.serviceName]) ??
          _getDynamic(_dynamicFallbackCounters, userKey, methodKey,
              _perKeyFallbackSpec) ??
          _globalCounter;
    } else {
      counter = _staticMethodCounters[methodKey] ??
          _staticServiceCounters[call.serviceName] ??
          _globalCounter;
    }

    if (counter == null) return;
    if (!counter.tryAcquire()) {
      throw RpcRateLimitException(
        'Rate limit exceeded for $methodKey'
        '${userKey != null ? ' (key: $userKey)' : ''}'
        ' (gRPC status $_statusResourceExhausted: RESOURCE_EXHAUSTED)',
      );
    }
  }

  @override
  Future<TResponse> interceptUnary<TRequest, TResponse>(
    RpcMiddlewareContext call,
    TRequest request,
    RpcUnaryNext<TRequest, TResponse> next,
  ) async {
    _check(call);
    return next(call.context, request);
  }

  @override
  FutureOr<Stream<TResponse>> interceptServerStream<TRequest, TResponse>(
    RpcMiddlewareContext call,
    TRequest request,
    RpcServerStreamNext<TRequest, TResponse> next,
  ) async {
    _check(call);
    return next(call.context, request);
  }

  @override
  Future<TResponse> interceptClientStream<TRequest, TResponse>(
    RpcMiddlewareContext call,
    Stream<TRequest> requests,
    RpcClientStreamNext<TRequest, TResponse> next,
  ) async {
    _check(call);
    return next(call.context, requests);
  }

  @override
  FutureOr<Stream<TResponse>> interceptBidirectionalStream<TRequest, TResponse>(
    RpcMiddlewareContext call,
    Stream<TRequest> requests,
    RpcBidirectionalStreamNext<TRequest, TResponse> next,
  ) async {
    _check(call);
    return next(call.context, requests);
  }
}

// ---------------------------------------------------------------------------
// Public exception type
// ---------------------------------------------------------------------------

/// Thrown by [RpcRateLimiter] when a call exceeds the configured limit.
class RpcRateLimitException extends RpcException {
  /// Creates an [RpcRateLimitException].
  RpcRateLimitException(super.message);
}
