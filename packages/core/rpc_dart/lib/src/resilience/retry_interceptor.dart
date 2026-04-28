// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:math';

import 'package:rpc_dart/rpc_dart.dart';

/// Predicate that decides whether an error is retryable.
typedef RpcRetryPredicate = bool Function(Object error);

/// Interceptor that retries failed unary calls with exponential backoff.
///
/// Only retries unary calls. Streaming calls pass through unchanged
/// because replaying a stream is not generally safe.
///
/// Usage:
/// ```dart
/// caller.addInterceptor(RpcRetryInterceptor(
///   maxAttempts: 3,
///   baseDelay: Duration(milliseconds: 200),
/// ));
/// ```
class RpcRetryInterceptor extends IRpcInterceptor {
  /// Maximum number of attempts (including the initial call).
  final int maxAttempts;

  /// Base delay between retries. Actual delay is `baseDelay * 2^attempt`
  /// with optional jitter.
  final Duration baseDelay;

  /// Maximum delay cap. Backoff will not exceed this.
  final Duration maxDelay;

  /// Whether to add random jitter to backoff delays.
  final bool jitter;

  /// Predicate to decide if an error is retryable.
  /// Defaults to retrying all errors except cancellation and deadline exceeded.
  final RpcRetryPredicate? retryOn;

  final Random _random = Random();

  /// Creates a retry interceptor.
  ///
  /// [maxAttempts] must be >= 1 (1 means no retries, just the initial call).
  RpcRetryInterceptor({
    this.maxAttempts = 3,
    this.baseDelay = const Duration(milliseconds: 200),
    this.maxDelay = const Duration(seconds: 5),
    this.jitter = true,
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

        final delay = _computeDelay(attempt);
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

    // Custom predicate.
    if (retryOn != null) return retryOn!(error);

    // Default: retry everything else.
    return true;
  }

  Duration _computeDelay(int attempt) {
    // Exponential backoff: baseDelay * 2^attempt.
    final exponential = baseDelay * pow(2, attempt);
    final capped = exponential > maxDelay ? maxDelay : exponential;

    if (!jitter) return capped;

    // Add jitter: random value between 0 and capped.
    final jitterMs = _random.nextInt(capped.inMilliseconds.clamp(1, 1 << 30));
    return Duration(milliseconds: jitterMs);
  }
}
