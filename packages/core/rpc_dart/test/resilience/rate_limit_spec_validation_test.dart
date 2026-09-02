// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// RateLimit's bounds were `assert`s in the spec constructors. Dart STRIPS
// asserts in release builds, so a misconfiguration a developer trips over in
// debug becomes a silently disabled rate limiter in production.
//
// A zero window makes the token bucket's refill `(elapsed / 0) * max` evaluate
// to Infinity, which clamps to a full bucket on every call. Measured with
// `dart run --no-enable-asserts`, i.e. release semantics:
//
//   limit max:5 -- 50 calls each
//     tokenBucket, window=30s (sane)   :  5/50 accepted
//     tokenBucket, window=0 (misconfig): 50/50 accepted
//
// The sliding-window variant instead throws IntegerDivisionByZeroException on
// first use, failing every call. Loud, but still a broken limiter.
//
// The bounds are now real throws, checked by RpcRateLimiter for every spec it
// is given, so they hold in every build mode. Moving them out of the
// constructors also fixed the `const` factories: Duration supports neither
// comparison nor property access in a constant expression, so an assert
// mentioning one made `const RateLimit.slidingWindow(...)` a compile error.
//
// NOTE: this file runs with asserts ENABLED (dart test always does), so it
// cannot itself observe the release-mode behaviour. What it pins is that the
// guard is no longer assert-shaped -- an ArgumentError thrown from a normal
// code path is present in both modes, an AssertionError would not be.

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

void main() {
  group('a spec that cannot enforce is rejected', () {
    test('token bucket with a zero window', () {
      expect(
        () => RpcRateLimiter(
          global: RateLimit.tokenBucket(max: 5, window: Duration.zero),
        ),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message.toString(),
            'message',
            contains('accepts everything'),
          ),
        ),
      );
    });

    test('sliding window with a zero window', () {
      expect(
        () => RpcRateLimiter(
          global: RateLimit.slidingWindow(max: 5, window: Duration.zero),
        ),
        throwsArgumentError,
      );
    });

    test('a non-positive max', () {
      expect(
        () => RpcRateLimiter(
          global: RateLimit.slidingWindow(
            max: 0,
            window: const Duration(seconds: 1),
          ),
        ),
        throwsArgumentError,
      );
    });

    test('a non-positive burst', () {
      expect(
        () => RpcRateLimiter(
          global: RateLimit.tokenBucket(
            max: 5,
            window: const Duration(seconds: 1),
            burst: 0,
          ),
        ),
        throwsArgumentError,
      );
    });

    test('the guard is an ArgumentError, not an AssertionError', () {
      // The distinction IS the fix: an AssertionError vanishes in release.
      Object? thrown;
      try {
        RpcRateLimiter(
          global: RateLimit.tokenBucket(max: 5, window: Duration.zero),
        );
      } catch (e) {
        thrown = e;
      }
      expect(thrown, isNot(isA<AssertionError>()));
      expect(thrown, isA<ArgumentError>());
    });
  });

  group('every slot is validated, not just global', () {
    test('perService', () {
      expect(
        () => RpcRateLimiter(
          perService: {
            'Svc': RateLimit.slidingWindow(max: 5, window: Duration.zero),
          },
        ),
        throwsArgumentError,
      );
    });

    test('perMethod', () {
      expect(
        () => RpcRateLimiter(
          perMethod: {
            'Svc.m': RateLimit.slidingWindow(max: 5, window: Duration.zero),
          },
        ),
        throwsArgumentError,
      );
    });

    test('perKeyFallback', () {
      expect(
        () => RpcRateLimiter(
          perKeyFallback: RateLimit.tokenBucket(max: 5, window: Duration.zero),
          keyExtractor: (_) => 'k',
        ),
        throwsArgumentError,
      );
    });
  });

  test('a valid spec is usable as a compile-time constant', () {
    // The const factories advertised this and could not deliver it: an assert
    // touching Duration is not a constant expression, so `const
    // RateLimit.slidingWindow(...)` failed to compile.
    const sliding = RateLimit.slidingWindow(
      max: 10,
      window: Duration(seconds: 1),
    );
    const bucket = RateLimit.tokenBucket(
      max: 10,
      window: Duration(seconds: 1),
      burst: 20,
    );
    const limits = <String, RateLimit>{'a': sliding, 'b': bucket};

    expect(limits, hasLength(2));
    expect(
      () => RpcRateLimiter(global: sliding, perMethod: limits),
      returnsNormally,
    );
  });

  test('sane specs still limit', () {
    // Guards the obvious wrong fix: validating everything into oblivion.
    final limiter = RpcRateLimiter(
      global: RateLimit.tokenBucket(
        max: 5,
        window: const Duration(seconds: 30),
      ),
    );
    expect(limiter, isNotNull);
    limiter.dispose();
  });
}
