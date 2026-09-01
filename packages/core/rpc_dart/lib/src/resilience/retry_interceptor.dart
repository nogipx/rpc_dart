// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'package:rpc_dart/rpc_dart.dart';

/// Predicate that decides whether an error is retryable.
typedef RpcRetryPredicate = bool Function(Object error);

/// Interceptor that retries failed unary calls with backoff.
///
/// Only retries unary calls. Streaming calls pass through unchanged
/// because replaying a stream is not generally safe.
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
  /// When null, the conservative gRPC-aligned default [_isTransient] is used:
  /// it retries ONLY clearly-transient errors (UNAVAILABLE,
  /// RESOURCE_EXHAUSTED, and connection/transport-closed errors). This avoids
  /// re-issuing non-idempotent calls (e.g. a write that committed server-side
  /// but lost its response) on arbitrary application errors. Provide an
  /// explicit predicate to customise; it fully replaces the default.
  final RpcRetryPredicate? retryOn;

  /// Creates a retry interceptor.
  ///
  /// [maxAttempts] must be >= 1 (1 means no retries, just the initial call).
  RpcRetryInterceptor({
    this.maxAttempts = 3,
    this.backoff = const ExponentialBackoff(
      baseDelay: Duration(milliseconds: 200),
      maxDelay: Duration(seconds: 5),
    ),
    this.retryOn,
  }) : assert(maxAttempts >= 1, 'maxAttempts must be >= 1');

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
          // Sleeping the whole backoff would push us past the caller's
          // deadline, and the attempt that follows would only fail with
          // DEADLINE_EXCEEDED. Give up now and surface the real transient
          // error instead of blocking the caller for up to `maxDelay` beyond
          // the deadline they asked for.
          break;
        }

        await Future<void>.delayed(delay);
      }
    }

    Error.throwWithStackTrace(lastError!, lastStack!);
  }

  bool _shouldRetry(Object error, RpcContext context) {
    // Never retry if cancelled or deadline exceeded.
    if (error is RpcCancelledException) return false;
    if (error is RpcDeadlineExceededException) return false;

    // Check deadline — no point retrying if no time left.
    if (context.deadline != null) {
      final remaining = context.remainingTime;
      if (remaining == null || remaining <= Duration.zero) return false;
    }

    // Custom predicate fully replaces the default.
    if (retryOn != null) return retryOn!(error);

    // Conservative default: only clearly-transient errors.
    return _isTransient(error);
  }

  /// Default transient-only predicate (gRPC-aligned).
  ///
  /// Retries only:
  /// - [RpcStatusException] with status UNAVAILABLE (14) or
  ///   RESOURCE_EXHAUSTED (8) — the connection/transport-closed and
  ///   server-overload signals the framework surfaces on the wire (e.g. a lost
  ///   connection becomes UNAVAILABLE "No response received");
  /// - [RpcRateLimitException] — a local RESOURCE_EXHAUSTED rejection.
  ///
  /// Arbitrary application errors (generic [RpcException], INTERNAL/INVALID_*
  /// status codes, and non-RPC exceptions) are NOT retried, so a
  /// non-idempotent call is not duplicated after a server-side commit.
  static bool _isTransient(Object error) {
    if (error is RpcRateLimitException) return true;
    if (error is RpcStatusException) {
      return error.statusCode == RpcStatus.unavailable ||
          error.statusCode == RpcStatus.resourceExhausted;
    }
    return false;
  }
}
