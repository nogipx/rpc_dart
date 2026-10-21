// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';

import '../_internal.dart';

/// Predicate that decides whether an error is retryable.
typedef RpcRetryPredicate = bool Function(Object error);

/// Interceptor that retries failed unary calls with backoff.
///
/// Only retries unary calls. Streaming calls pass through unchanged
/// because replaying a stream is not generally safe.
///
/// ## Retries require an IDEMPOTENT method
///
/// The default predicate retries `UNAVAILABLE`, which is also the status a call
/// gets when the server processed it and the RESPONSE was lost. The two are
/// indistinguishable from the client, so a retry re-issues work that may already
/// have committed — and the caller cannot tell, because it is handed a success
/// either way. At `maxAttempts: 3` one logical call can commit three times.
///
/// This is the standard gRPC retry trade-off rather than a quirk of this
/// implementation, but enabling it only where re-execution is safe is the
/// caller's job. Do not attach it to a charge, an append or a "send email"
/// unless the server deduplicates by request id — [RpcContext] carries
/// `requestId` for exactly that.
///
/// A server that pushes back names its own delay: an error carrying an
/// [RpcRetryInfo] with a positive `retryDelay` waits that long instead of
/// [backoff], as gRPC clients do. A zero `retryDelay` (a capacity limit that
/// frees up by itself) waits [backoff].
///
/// The wait never outlives the call's deadline: when the next delay would
/// not fit in [RpcContext.remainingTime], the retry is abandoned and the last
/// error is rethrown immediately rather than after a sleep the caller did not
/// budget for. A cancel cuts it short.
///
/// Usage:
/// ```dart
/// caller.addInterceptor(RpcRetryInterceptor(
///   maxAttempts: 3,
///   backoff: ExponentialBackoff(baseDelay: Duration(milliseconds: 200)),
/// ));
/// ```
class RpcRetryInterceptor extends IRpcInterceptor {
  /// Maximum number of attempts (including the initial call).
  final int maxAttempts;

  /// Backoff strategy for computing delays between retries.
  final BackoffPolicy backoff;

  /// Predicate to decide if an error is retryable.
  ///
  /// When null, the conservative gRPC-aligned default [_isTransient] applies:
  /// only UNAVAILABLE, RESOURCE_EXHAUSTED and transport-closed errors are
  /// retried, so an arbitrary application error — a generic [RpcException],
  /// INTERNAL, INVALID_ARGUMENT, a non-RPC throw — never causes a second
  /// attempt.
  ///
  /// **That is the whole of the guarantee, and it does NOT cover a lost
  /// response**, which IS `UNAVAILABLE` and so is exactly what the default
  /// retries. See the class doc.
  ///
  /// An explicit predicate fully replaces the default. To retry only where
  /// re-execution is safe, attach the interceptor to an endpoint used for
  /// idempotent methods alone, or deduplicate server-side on
  /// [RpcContext.requestId].
  final RpcRetryPredicate? retryOn;

  /// Creates a retry interceptor.
  ///
  /// [maxAttempts] must be >= 1 (1 means no retries, just the initial call).
  /// Throws [ArgumentError] otherwise.
  ///
  /// A real throw, not an `assert`, which Dart strips in release builds. At
  /// `maxAttempts: 0` the attempt loop never runs and [interceptUnary] falls
  /// through to `Error.throwWithStackTrace(lastError!, lastStack!)` on two
  /// nulls, so every call dies of a null check having never reached the
  /// transport.
  RpcRetryInterceptor({
    this.maxAttempts = 3,
    this.backoff = const ExponentialBackoff(
      baseDelay: Duration(milliseconds: 200),
      maxDelay: Duration(seconds: 5),
    ),
    this.retryOn,
  }) {
    if (maxAttempts < 1) {
      throw ArgumentError.value(
        maxAttempts,
        'maxAttempts',
        'must be >= 1 (1 means no retries, just the initial call)',
      );
    }
  }

  @override
  Future<TResponse> interceptUnary<TRequest, TResponse>(
    RpcMiddlewareContext call,
    TRequest request,
    RpcUnaryNext<TRequest, TResponse> next,
  ) async {
    Object? lastError;
    StackTrace? lastStack;

    for (var attempt = 0; attempt < maxAttempts; attempt++) {
      try {
        return await next(call.context, request);
      } catch (e, st) {
        lastError = e;
        lastStack = st;

        final isLastAttempt = attempt == maxAttempts - 1;
        if (isLastAttempt || !_shouldRetry(e, call.context)) {
          break;
        }

        final delay = _pushbackDelay(e) ?? backoff.delayFor(attempt);
        final remaining = call.context.remainingTime;
        if (remaining != null && delay >= remaining) {
          // Sleeping the whole backoff would pass the caller's deadline, and
          // the attempt after it could only fail DEADLINE_EXCEEDED. Give up now
          // and surface the real transient error rather than blocking for up to
          // `maxDelay` beyond the deadline the caller asked for.
          break;
        }

        await _backoff(delay, call.context.cancellationToken);
        // A call cancelled during the backoff neither starts a reconnect nor
        // waits for one; the next attempt fails CANCELLED at once.
        if (call.context.cancellationToken?.isCancelled ?? false) continue;
        await _awaitReconnectIfConnectionIsGone(e, call);
      }
    }

    Error.throwWithStackTrace(lastError!, lastStack!);
  }

  /// The positive delay [error]'s [RpcRetryInfo] asks for, or null.
  static Duration? _pushbackDelay(Object error) {
    if (error is! RpcStatusException) return null;
    for (final detail in error.details) {
      if (detail is RpcRetryInfo && detail.retryDelay > Duration.zero) {
        return detail.retryDelay;
      }
    }
    return null;
  }

  /// Waits [delay], or less if [token] is cancelled first.
  ///
  /// The next attempt reads the token and fails CANCELLED at once, so a cancel
  /// during the backoff ends the call when it is made, not up to `maxDelay`
  /// later.
  static Future<void> _backoff(Duration delay, RpcCancellationToken? token) {
    if (token == null) return Future<void>.delayed(delay);
    if (token.isCancelled) return Future<void>.value();
    final elapsed = Completer<void>();
    final timer = Timer(delay, elapsed.complete);
    return Future.any([
      elapsed.future,
      token.cancelled,
    ]).whenComplete(timer.cancel);
  }

  /// Waits, before an UNAVAILABLE retry, for the connection to come back when
  /// it is gone: an attempt on a dead transport can only fail the same way and
  /// spend the caller's deadline doing it.
  ///
  /// UNAVAILABLE only. RESOURCE_EXHAUSTED means the peer is overloaded and its
  /// connection is fine.
  ///
  /// UNAVAILABLE alone does not mean the connection is gone: a handler may
  /// throw it, a draining server answers it, a truncated stream synthesises
  /// it. So the transport's health is asked, which is about the connection
  /// where the status is only about this call.
  ///
  /// Only a transport with an [IRpcTransport.reconnectOutcome] waits here --
  /// [RpcClientConnection]'s, or a decorator forwarding it; over a bare
  /// transport the retry goes back to the same one. The wait is for the connection's next attempt, which runs on
  /// its own backoff and is started by nothing here. Either way the original
  /// error is what the caller sees.
  Future<void> _awaitReconnectIfConnectionIsGone(
    Object error,
    RpcMiddlewareContext call,
  ) async {
    if (error is! RpcStatusException) return;
    if (error.statusCode != RpcStatus.unavailable) return;
    final transport = call.endpoint.transport;
    final reconnect = transport.reconnectOutcome;
    if (reconnect == null) return;
    try {
      if ((await transport.health()).isHealthy) return;
      await _withinCall(reconnect.awaitReconnect(), call.context);
    } catch (_) {
      // A health() or a wait that throws tells nothing: the attempt below runs
      // and reports for itself.
    }
  }

  /// How early a Timer may fire against the context's clock and still be
  /// re-armed; see [_withinCall].
  static const Duration _earlyFire = Duration(milliseconds: 50);

  /// Waits for [reconnect] no longer than the call has left: its deadline, or
  /// its cancellation. A reconnect can take seconds -- behind
  /// [RpcClientConnection] it waits up to 5 s for the next attempt -- and a
  /// call is not held past the deadline its caller set. The reconnect itself
  /// runs on; the attempt after it fails DEADLINE_EXCEEDED or CANCELLED.
  static Future<void> _withinCall(
    Future<RpcHealthStatus> reconnect,
    RpcContext context,
  ) {
    final remaining = context.remainingTime;
    final token = context.cancellationToken;
    if (remaining == null && token == null) return reconnect;
    Timer? timer;
    final ends = <Future<void>>[reconnect];
    if (remaining != null) {
      final expired = Completer<void>();
      // A Timer runs in whole milliseconds, the deadline on the context's
      // clock, and the Timer can fire before the context sees the deadline
      // pass; the next attempt would then find time left and fail UNAVAILABLE.
      // So the wait re-arms for that sliver. A larger rest means an injected
      // clock went back, and the wait ends on time anyway: re-armed for it, it
      // would run to the reconnect's own 5 s limit.
      //
      // A deadline can be past the web's timer ceiling, where a plain Timer
      // fires at once and the reconnect would not be waited for.
      void arm(Duration left) {
        timer = RpcLongTimer.create(left, () {
          final rest = context.remainingTime!;
          if (rest > Duration.zero && rest < _earlyFire) {
            arm(rest);
          } else {
            expired.complete();
          }
        });
      }

      arm(remaining);
      ends.add(expired.future);
    }
    if (token != null) ends.add(token.cancelled);
    return Future.any(ends).whenComplete(() => timer?.cancel());
  }

  bool _shouldRetry(Object error, RpcContext context) {
    if (error is RpcCancelledException) return false;
    if (error is RpcDeadlineExceededException) return false;

    if (context.deadline != null) {
      final remaining = context.remainingTime;
      if (remaining == null || remaining <= Duration.zero) return false;
    }

    if (retryOn != null) return retryOn!(error);

    return _isTransient(error);
  }

  /// Default transient-only predicate (gRPC-aligned).
  ///
  /// Retries [RpcStatusException] with UNAVAILABLE (14), and RESOURCE_EXHAUSTED
  /// (8) only with server pushback ([RpcStatusException.isPushback]).
  /// Everything else, including a generic [RpcException], an INTERNAL or
  /// INVALID_* status and any non-RPC throw, is not retried.
  ///
  /// Does NOT make a non-idempotent call safe: UNAVAILABLE covers both "the
  /// server never saw it" and "the server committed it and the response was
  /// lost", and nothing on the wire tells them apart.
  static bool _isTransient(Object error) =>
      error is RpcStatusException &&
      (error.statusCode == RpcStatus.unavailable || error.isPushback);
}
