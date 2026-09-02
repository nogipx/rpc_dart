// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// Every remaining `assert` in lib/ (outside the frozen logger) guarded a
// user-supplied configuration value. Dart STRIPS asserts in release builds, so
// each was a guard that existed only where it was not needed. Measured with
// `dart run --no-enable-asserts`, i.e. release semantics:
//
//   RpcRetryInterceptor(maxAttempts: 0)
//     -> _TypeError: Null check operator used on a null value
//        The attempt loop never runs, so interceptUnary falls through to
//        Error.throwWithStackTrace(lastError!, lastStack!) on two nulls -- and
//        the RPC was never attempted.
//
//   RpcRateLimiter(maxTrackedKeys: 0)
//     -> RpcStatusException(13): Bad state: No element
//        _getDynamic evicts when `store.length >= _maxTrackedKeys`, true on an
//        EMPTY map, so `store.keys.first` throws. Reached the client as
//        INTERNAL on every call.
//
//   RpcResponderMethodBinding with neither registration
//     -> survives construction, fails later at codecMethod/zeroCopyMethod with
//        a bare null-check error pointing at dispatch, not at the malformed
//        registration.
//
// None is a silent bypass (unlike the zero-window rate limit, which accepted
// 50/50 requests against max: 5 -- see rate_limit_spec_validation_test.dart),
// but all three fail confusingly and blame the wrong place. They are now
// ArgumentError throws, which hold in every build mode.
//
// NOTE: this file runs with asserts ENABLED, as `dart test` always does, so it
// cannot observe release behaviour directly. What it pins is that the guard is
// no longer assert-shaped: an ArgumentError from a normal code path exists in
// both modes, an AssertionError does not.

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

/// Fails if [body] throws an [AssertionError] — the shape that vanishes.
void expectsSurvivingGuard(String what, void Function() body) {
  Object? thrown;
  try {
    body();
  } catch (e) {
    thrown = e;
  }
  expect(thrown, isNotNull, reason: '$what was not rejected at all');
  expect(
    thrown,
    isNot(isA<AssertionError>()),
    reason: '$what is guarded by an assert, which release builds strip',
  );
  expect(
    thrown,
    isA<ArgumentError>(),
    reason:
        '$what should be an argument '
        'error naming the bad value',
  );
}

void main() {
  group('config guards survive release builds', () {
    test('RpcRetryInterceptor rejects maxAttempts < 1', () {
      expectsSurvivingGuard(
        'maxAttempts: 0',
        () => RpcRetryInterceptor(maxAttempts: 0),
      );
      expectsSurvivingGuard(
        'maxAttempts: -1',
        () => RpcRetryInterceptor(maxAttempts: -1),
      );
    });

    test('RpcRateLimiter rejects maxTrackedKeys < 1', () {
      expectsSurvivingGuard(
        'maxTrackedKeys: 0',
        () => RpcRateLimiter(maxTrackedKeys: 0),
      );
    });

    test('RpcResponderMethodBinding rejects having no registration', () {
      expectsSurvivingGuard(
        'a binding with neither variant',
        () => RpcResponderMethodBinding(
          serviceName: 'Svc',
          methodName: 'm',
          type: RpcMethodType.unaryRequest,
        ),
      );
    });
  });

  group('valid configuration is untouched', () {
    test('the documented defaults construct', () {
      expect(() => RpcRetryInterceptor(), returnsNormally);
      expect(() => RpcRateLimiter(), returnsNormally);
    });

    test('maxAttempts: 1 means no retries, and is legal', () {
      expect(() => RpcRetryInterceptor(maxAttempts: 1), returnsNormally);
    });

    test('a binding with either variant alone constructs', () {
      expect(
        () => RpcResponderMethodBinding(
          serviceName: 'Svc',
          methodName: 'm',
          type: RpcMethodType.unaryRequest,
          zeroCopyRegistration: RpcZeroCopyMethodRegistration<Object, Object>(
            name: 'm',
            type: RpcMethodType.unaryRequest,
            handler: (Object r, {RpcContext? context}) async => r,
            description: '',
          ),
        ),
        returnsNormally,
      );
    });
  });

  test('a retry interceptor with a valid config still retries', () async {
    // Guards the wrong fix: rejecting the whole configuration space.
    var attempts = 0;
    final interceptor = RpcRetryInterceptor(
      maxAttempts: 3,
      backoff: const ExponentialBackoff(
        baseDelay: Duration(milliseconds: 1),
        maxDelay: Duration(milliseconds: 2),
      ),
      retryOn: (_) => true,
    );

    final call = RpcMiddlewareContext(
      endpoint: RpcCallerEndpoint(transport: RpcChannelTransport.pair().$1),
      serviceName: 'Svc',
      methodName: 'm',
      context: RpcContext.empty(),
    );

    await expectLater(
      interceptor.interceptUnary<String, String>(call, 'req', (ctx, req) async {
        attempts++;
        throw RpcStatusException(RpcStatus.unavailable, 'nope');
      }),
      throwsA(isA<RpcStatusException>()),
    );
    expect(attempts, 3, reason: 'all attempts should have been made');
  });
}
