// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// ExponentialBackoff worked in whole milliseconds, so a base under 1 ms
// truncated to 0 -- and the overflow guard read 0 as "too large" and answered
// maxDelay. `baseDelay: Duration.zero`, which reads as "no delay", slept the
// maximum (60 s by default) before every retry and reconnect. With jitter,
// Random.nextInt's 2^32 limit made a maxDelay past ~50 days throw.

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

void main() {
  const max = Duration(seconds: 30);

  test('a base under a millisecond grows from itself', () {
    const b = ExponentialBackoff(
      baseDelay: Duration(microseconds: 500),
      maxDelay: max,
      jitter: false,
    );
    expect(b.delayFor(0), const Duration(microseconds: 500));
    expect(b.delayFor(1), const Duration(milliseconds: 1));
    expect(b.delayFor(5), const Duration(milliseconds: 16));
  });

  test('a zero base means no delay', () {
    const b = ExponentialBackoff(
      baseDelay: Duration.zero,
      maxDelay: max,
      jitter: false,
    );
    for (final attempt in [0, 1, 5, 100]) {
      expect(b.delayFor(attempt), Duration.zero);
    }
  });

  test('CONTROL: whole milliseconds, capped, at any attempt', () {
    const b = ExponentialBackoff(
      baseDelay: Duration(milliseconds: 1),
      maxDelay: max,
      jitter: false,
    );
    expect(b.delayFor(0), const Duration(milliseconds: 1));
    expect(b.delayFor(5), const Duration(milliseconds: 32));
    expect(b.delayFor(31), max);
    expect(b.delayFor(1 << 40), max);
    expect(b.delayFor(-1), const Duration(milliseconds: 1));
  });

  test('jitter stays inside (0, cap] at a cap past 2^32 microseconds', () {
    const b = ExponentialBackoff(
      baseDelay: Duration(days: 1),
      maxDelay: Duration(days: 50),
    );
    for (var i = 0; i < 100; i++) {
      final d = b.delayFor(10);
      expect(d, greaterThan(Duration.zero));
      expect(d, lessThanOrEqualTo(const Duration(days: 50)));
    }
  });
}
