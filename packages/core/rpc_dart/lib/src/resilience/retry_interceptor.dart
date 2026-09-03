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
/// ## Retries require an IDEMPOTENT method
///
/// The default predicate retries `UNAVAILABLE`, which is also the status a
/// call gets when the server processed it and the RESPONSE was lost. Those two
/// are indistinguishable from the client, so a retry re-issues work that may
/// already have committed. This is the standard gRPC retry trade-off, not a
/// quirk of this implementation, but it is the caller's job to only enable it
/// where re-execution is safe.
///
/// Measured with a handler that commits and then loses its response, for ONE
/// logical call at `maxAttempts: 3`:
///
///   response lost once  -> 2 server-side commits, caller saw SUCCESS
///   response lost twice -> 3 server-side commits, caller saw SUCCESS
///   no loss (control)   -> 1 commit
///
/// The caller cannot tell: it is handed a successful result either way. Do not
/// attach this to a non-idempotent method (a charge, an append, a "send
/// email") unless the server deduplicates by request id -- [RpcContext] carries
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
  /// When null, the conservative gRPC-aligned default [_isTransient] is used:
  /// it retries ONLY clearly-transient errors (UNAVAILABLE,
  /// RESOURCE_EXHAUSTED, and connection/transport-closed errors), so an
  /// arbitrary application error -- a generic [RpcException], INTERNAL,
  /// INVALID_ARGUMENT, a non-RPC throw -- never causes a second attempt.
  ///
  /// That is the whole of the guarantee. This doc used to add "(e.g. a write
  /// that committed server-side but lost its response)" as an example of what
  /// the default avoids re-issuing, which was backwards: a lost response IS
  /// `UNAVAILABLE`, so it is exactly the case the default DOES retry. Measured
  /// at `maxAttempts: 3`, a handler that commits and then loses its response
  /// committed twice for one call and the caller was handed a success. See the
  /// class doc.
  ///
  /// Provide an explicit predicate to customise; it fully replaces the default.
  /// To retry only where re-execution is safe, gate on the method:
  ///
  /// ```dart
  /// const idempotent = {'/Catalog/Get', '/Catalog/List'};
  /// RpcRetryInterceptor(
  ///   retryOn: (e) =>
  ///       e is RpcStatusException && e.statusCode == RpcStatus.unavailable,
  /// );
  /// // ...and attach it only to an endpoint used for those methods, or
  /// // deduplicate server-side on RpcContext.requestId.
  /// ```
  final RpcRetryPredicate? retryOn;

  /// Creates a retry interceptor.
  ///
  /// [maxAttempts] must be >= 1 (1 means no retries, just the initial call).
  /// Throws [ArgumentError] otherwise.
  ///
  /// This was an `assert`, which Dart strips in release builds. With
  /// `maxAttempts: 0` the attempt loop never runs, so `interceptUnary` falls
  /// straight through to `Error.throwWithStackTrace(lastError!, lastStack!)`
  /// on two nulls: every call through the interceptor died with `Null check
  /// operator used on a null value`, having never reached the transport. A
  /// real throw names the actual mistake, at construction, in every build mode.
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
  /// status codes, and non-RPC exceptions) are NOT retried.
  ///
  /// This does NOT make a non-idempotent call safe. UNAVAILABLE covers both
  /// "the server never saw it" and "the server committed it and the response
  /// was lost", and nothing on the wire distinguishes them -- see the class
  /// doc for the measurement.
  static bool _isTransient(Object error) {
    if (error is RpcRateLimitException) return true;
    if (error is RpcStatusException) {
      return error.statusCode == RpcStatus.unavailable ||
          error.statusCode == RpcStatus.resourceExhausted;
    }
    return false;
  }
}
