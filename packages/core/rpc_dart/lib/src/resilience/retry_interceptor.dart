// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

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
/// The backoff never outlives the call's deadline: when the next delay would
/// not fit in [RpcContext.remainingTime], the retry is abandoned and the last
/// error is rethrown immediately rather than after a sleep the caller did not
/// budget for.
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

        final delay = backoff.delayFor(attempt);
        final remaining = call.context.remainingTime;
        if (remaining != null && delay >= remaining) {
          // Sleeping the whole backoff would pass the caller's deadline, and
          // the attempt after it could only fail DEADLINE_EXCEEDED. Give up now
          // and surface the real transient error rather than blocking for up to
          // `maxDelay` beyond the deadline the caller asked for.
          break;
        }

        await Future<void>.delayed(delay);
      }
    }

    Error.throwWithStackTrace(lastError!, lastStack!);
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
  /// Retries [RpcStatusException] with UNAVAILABLE (14) or RESOURCE_EXHAUSTED
  /// (8) — the transport-closed and server-overload signals the framework puts
  /// on the wire — plus [RpcRateLimitException], the local form of the second.
  /// Everything else, including a generic [RpcException], an INTERNAL or
  /// INVALID_* status and any non-RPC throw, is not retried.
  ///
  /// Does NOT make a non-idempotent call safe: UNAVAILABLE covers both "the
  /// server never saw it" and "the server committed it and the response was
  /// lost", and nothing on the wire tells them apart.
  static bool _isTransient(Object error) {
    if (error is RpcRateLimitException) return true;
    if (error is RpcStatusException) {
      return error.statusCode == RpcStatus.unavailable ||
          error.statusCode == RpcStatus.resourceExhausted;
    }
    return false;
  }
}
