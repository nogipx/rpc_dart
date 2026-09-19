// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// `wireStatusFor` is DEFAULT DENY: only RpcStatusException and rpc_dart's own
// RpcException hierarchy reach a peer intact, everything else is redacted to
// INTERNAL(13) "Internal server error". Three library types sat OUTSIDE that
// hierarchy, implementing `Exception` directly:
//
//   RpcCancelledException         contracts/context.dart
//   RpcDeadlineExceededException  contracts/context.dart
//   CircuitBreakerOpenException   resilience/circuit_breaker_interceptor.dart
//
// So a handler throwing a cancellation was indistinguishable from one throwing
// a foreign StateError. Measured over a real socket, before and after:
//
//   cancelled   status 13 "Internal server error"  ->  status 1 "handler cancelled"
//   deadline    status 13 "Internal server error"  ->  status 4 "Deadline ... exceeded"
//
// `wireStatusFor`'s own doc had explained the exclusion and added a claim —
// "the responder pipeline answers both with their own status long before an
// error is translated". The cycle it names is real; the claim was not.
//
// The fix is at the TYPE, not at the mapper: these extend RpcStatusException,
// so wireStatusFor needed no change and the deny stayed exactly as strict.

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

void main() {
  group('every library error is in one hierarchy', () {
    // WITNESS: all three implemented `Exception` directly, so the one catch a
    // user would write to mean "an rpc_dart error" missed them.
    test('a single catch finds them all', () {
      final errors = <Object>[
        const RpcCancelledException('cancelled'),
        RpcDeadlineExceededException(
          DateTime(2026),
          const Duration(seconds: 1),
        ),
        const CircuitBreakerOpenException(),
        RpcException('base'),
        RpcStatusException(RpcStatus.notFound, 'missing'),
      ];

      for (final e in errors) {
        expect(
          e,
          isA<RpcException>(),
          reason: '${e.runtimeType} is outside the hierarchy again',
        );
      }
    });

    // WITNESS: the status is what reaches the peer, and it was INTERNAL.
    test('each carries the status gRPC has for it', () {
      expect(const RpcCancelledException('x').statusCode, RpcStatus.cancelled);
      expect(
        RpcDeadlineExceededException(
          DateTime(2026),
          const Duration(seconds: 1),
        ).statusCode,
        RpcStatus.deadlineExceeded,
      );
      expect(
        const CircuitBreakerOpenException().statusCode,
        RpcStatus.unavailable,
        reason: 'an open breaker is "try again later", which is UNAVAILABLE',
      );
    });

    // WITNESS: this is the behaviour the types buy. Before, all three of these
    // returned INTERNAL and the redacted message.
    test('wireStatusFor forwards them intact', () {
      final cancelled = wireStatusFor(const RpcCancelledException('by peer'));
      expect(cancelled.status, RpcStatus.cancelled);
      expect(cancelled.message, 'by peer');

      final deadline = wireStatusFor(
        RpcDeadlineExceededException(
          DateTime(2026),
          const Duration(seconds: 1),
        ),
      );
      expect(deadline.status, RpcStatus.deadlineExceeded);
      expect(deadline.message, contains('Deadline'));
    });

    // GUARD, and the load-bearing one: widening the hierarchy must not widen
    // the DENY. A foreign error's text is internal state and reached
    // unauthenticated peers before the deny became the default.
    test('a foreign error is still redacted', () {
      final foreign = wireStatusFor(StateError('a secret internal detail'));
      expect(foreign.status, RpcStatus.internal);
      expect(foreign.message, kInternalErrorWireMessage);
      expect(foreign.message, isNot(contains('secret')));

      final alsoForeign = wireStatusFor(FormatException('/etc/passwd'));
      expect(alsoForeign.message, kInternalErrorWireMessage);
    });

    // GUARD: `on X catch` still selects the specific type. Subclassing must not
    // make callers catch more than they asked for — rpc_data has four such
    // sites and the retry interceptor two.
    test('the specific types are still selectable', () {
      Object? caught;
      try {
        throw const RpcCancelledException('precise');
      } on RpcDeadlineExceededException {
        caught = 'WRONG — caught the sibling';
      } on RpcCancelledException catch (e) {
        caught = e;
      }
      expect(caught, isA<RpcCancelledException>());
    });

    // GUARD: const-ness is public API and two call sites in the breaker use it.
    test('the const constructors are still const', () {
      const a = RpcCancelledException('x');
      const b = CircuitBreakerOpenException();
      const c = RpcStatusException(RpcStatus.notFound, 'y');
      expect(identical(a, const RpcCancelledException('x')), isTrue);
      expect(b.statusCode, RpcStatus.unavailable);
      expect(c.statusCode, RpcStatus.notFound);
    });

    // GUARD: the rendered text is unchanged, so logs and golden output do not
    // move. The breaker keeps its retryAfter in toString() for this reason.
    test('toString is unchanged', () {
      expect(
        const RpcCancelledException('why').toString(),
        'RpcCancelledException: why',
      );
      expect(
        const CircuitBreakerOpenException(
          retryAfter: Duration(milliseconds: 250),
        ).toString(),
        'CircuitBreakerOpenException: circuit is open, retry after 250ms',
      );
      expect(
        const CircuitBreakerOpenException().toString(),
        'CircuitBreakerOpenException: circuit is open',
      );
    });
  });
}
