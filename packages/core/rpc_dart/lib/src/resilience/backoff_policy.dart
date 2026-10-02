// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:math';

/// Strategy for computing delays between retry/reconnect attempts.
///
/// Built-in implementations:
/// - [ExponentialBackoff] — `baseDelay * 2^attempt`, capped at [maxDelay], optional jitter.
/// - [FixedBackoff] — constant delay.
///
/// Extend this class for custom strategies.
abstract class BackoffPolicy {
  /// Creates a [BackoffPolicy].
  const BackoffPolicy();

  /// Computes the delay before the given [attempt] (0-based).
  Duration delayFor(int attempt);
}

/// Exponential backoff: `baseDelay * 2^attempt`, capped at [maxDelay].
///
/// When [jitter] is `true`, the actual delay is a random value between 0 and
/// the computed delay. This prevents thundering-herd effects when many clients
/// reconnect simultaneously.
///
/// ```dart
/// const backoff = ExponentialBackoff(
///   baseDelay: Duration(milliseconds: 200),
///   maxDelay: Duration(seconds: 30),
/// );
/// backoff.delayFor(0); // ~200ms (with jitter)
/// backoff.delayFor(3); // ~1600ms (with jitter)
/// ```
class ExponentialBackoff extends BackoffPolicy {
  /// Base delay for the first attempt.
  final Duration baseDelay;

  /// Maximum delay cap. Backoff will not exceed this.
  final Duration maxDelay;

  /// Whether to randomize the delay (recommended for production).
  final bool jitter;

  /// Creates an [ExponentialBackoff] policy.
  const ExponentialBackoff({
    this.baseDelay = const Duration(seconds: 1),
    this.maxDelay = const Duration(seconds: 60),
    this.jitter = true,
  });

  static final _random = Random();

  @override
  Duration delayFor(int attempt) {
    // Microseconds: in milliseconds a base under 1 ms truncated to 0, which
    // the overflow guard then read as "too large" and turned into maxDelay --
    // so `baseDelay: Duration.zero` slept the maximum on every attempt.
    final baseUs = baseDelay.inMicroseconds;
    final maxUs = maxDelay.inMicroseconds;
    if (baseUs <= 0 || maxUs <= 0) return Duration.zero;

    // Compared before multiplying, so nothing can overflow; and with `~/`
    // and `*` rather than shifts, which are 32-bit on the web.
    final factor = 1 << attempt.clamp(0, 30);
    final cappedUs = baseUs > maxUs ~/ factor ? maxUs : baseUs * factor;

    if (!jitter) return Duration(microseconds: cappedUs);

    // Uniform in [1, cap] whole milliseconds, as it always was; in
    // microseconds only for a cap under one. nextDouble, not nextInt: nextInt
    // takes at most 2^32 and threw past ~50 days.
    final unit = cappedUs >= 1000 ? 1000 : 1;
    final units = cappedUs ~/ unit;
    final picked = (_random.nextDouble() * units).floor() + 1;
    return Duration(microseconds: (picked > units ? units : picked) * unit);
  }
}

/// Fixed delay between every attempt.
///
/// ```dart
/// const backoff = FixedBackoff(Duration(seconds: 2));
/// backoff.delayFor(0); // 2s
/// backoff.delayFor(99); // 2s
/// ```
class FixedBackoff extends BackoffPolicy {
  /// The constant delay between attempts.
  final Duration delay;

  /// Creates a [FixedBackoff] policy.
  const FixedBackoff(this.delay);

  @override
  Duration delayFor(int attempt) => delay;
}
