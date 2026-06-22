// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// Audit findings (core audit, round 2):
//
// 1. num.dart: RpcNum.operator ~/ guarded with the subtype-based _isDoubleTyped
//    but then fell through to a raw `a is int && b is int` check. On dart2js
//    `7.0 is int` is true, so `RpcNum(7.0) ~/ RpcNum(2.0)` threw on the VM but
//    returned a value on dart2js — a platform divergence. `~/` is well-defined
//    for any num, so it is now computed directly and is platform-stable.
//
// 2. rate_limiter.dart: RateLimit.slidingWindow / .tokenBucket accepted a
//    zero/negative max and a zero window with no validation, which divides by
//    zero (sliding window) or yields NaN/Infinity (token bucket) at runtime.

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

void main() {
  group('RpcNum integer division is platform-stable', () {
    test(
      'RpcNum(7.0) ~/ RpcNum(2.0) computes consistently (no VM-only throw)',
      () {
        final result = RpcNum(7.0) ~/ RpcNum(2.0);
        expect(result.value, 3);
      },
    );

    test('integer operands still divide', () {
      expect((RpcNum(7) ~/ RpcNum(2)).value, 3);
    });

    test('a double-typed operand is still rejected', () {
      expect(
        () => RpcNum(7.0) ~/ RpcDouble(2.0),
        throwsA(anything),
        reason: 'a known-double operand must be rejected by the subtype guard',
      );
    });
  });

  group('RateLimit specs validate their arguments', () {
    test('slidingWindow rejects max <= 0', () {
      expect(
        () =>
            RateLimit.slidingWindow(max: 0, window: const Duration(seconds: 1)),
        throwsA(isA<AssertionError>()),
      );
    });

    test('slidingWindow rejects a zero window', () {
      expect(
        () => RateLimit.slidingWindow(max: 10, window: Duration.zero),
        throwsA(isA<AssertionError>()),
      );
    });

    test('tokenBucket rejects a zero window and a zero burst', () {
      expect(
        () => RateLimit.tokenBucket(max: 10, window: Duration.zero),
        throwsA(isA<AssertionError>()),
      );
      expect(
        () => RateLimit.tokenBucket(
          max: 10,
          window: const Duration(seconds: 1),
          burst: 0,
        ),
        throwsA(isA<AssertionError>()),
      );
    });

    test('valid specs construct without error', () {
      expect(
        () => RateLimit.slidingWindow(
          max: 10,
          window: const Duration(seconds: 1),
        ),
        returnsNormally,
      );
      expect(
        () => RateLimit.tokenBucket(
          max: 10,
          window: const Duration(seconds: 1),
          burst: 5,
        ),
        returnsNormally,
      );
    });
  });
}
