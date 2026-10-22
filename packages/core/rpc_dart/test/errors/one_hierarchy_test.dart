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
//   RpcCircuitBreakerOpenException   resilience/circuit_breaker_interceptor.dart
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

import 'package:rpc_dart/transport.dart';
import 'package:test/test.dart';

void main() {
  group('every library error is in one hierarchy', () {
    // WITNESS: all three implemented `Exception` directly, so the one catch a
    // user would write to mean "an rpc_dart error" missed them.
    test('a single catch finds them all', () {
      final errors = <Object>[
        RpcCancelledException('cancelled'),
        RpcDeadlineExceededException(DateTime(2026)),
        RpcCircuitBreakerOpenException(),
        _LibraryAuthored('a subclass carrying no status of its own'),
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
      expect(RpcCancelledException('x').statusCode, RpcStatus.cancelled);
      expect(
        RpcDeadlineExceededException(DateTime(2026)).statusCode,
        RpcStatus.deadlineExceeded,
      );
      expect(
        RpcCircuitBreakerOpenException().statusCode,
        RpcStatus.unavailable,
        reason: 'an open breaker is "try again later", which is UNAVAILABLE',
      );
    });

    // WITNESS: this is the behaviour the types buy. Before, all three of these
    // returned INTERNAL and the redacted message.
    test('wireStatusFor forwards them intact', () {
      final cancelled = wireStatusFor(RpcCancelledException('by peer'));
      expect(cancelled.status, RpcStatus.cancelled);
      expect(cancelled.message, 'by peer');

      final deadline = wireStatusFor(
        RpcDeadlineExceededException(DateTime(2026)),
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
        throw RpcCancelledException('precise');
      } on RpcDeadlineExceededException {
        caught = 'WRONG — caught the sibling';
      } on RpcCancelledException catch (e) {
        caught = e;
      }
      expect(caught, isA<RpcCancelledException>());
    });

    // GUARD: a status exception of the caller's own stays const-constructible.
    // The cancelled and breaker exceptions are not const, so they can gain
    // computed details.
    test('RpcStatusException is still const', () {
      const c = RpcStatusException(RpcStatus.notFound, 'y');
      expect(c.statusCode, RpcStatus.notFound);
    });

    // validateMetadata judges UNTRUSTED PEER input, and the decision points that
    // catch it -- two of them deciding whether to END A CONNECTION -- read it as
    // "the peer is at fault". So it is its own type, in the hierarchy, and NOT
    // an ArgumentError: an ArgumentError is a programming mistake, and one
    // raised on that path must not be charged to the peer's 256-strike budget.
    test('a metadata violation is an RpcException, not an ArgumentError', () {
      const policy = RpcSecurityPolicy(maxHeaders: 2);
      Object? thrown;
      try {
        policy.validateMetadata(
          RpcMetadata([
            RpcHeader('a', '1'),
            RpcHeader('b', '2'),
            RpcHeader('c', '3'),
          ]),
        );
      } catch (e) {
        thrown = e;
      }

      expect(thrown, isA<RpcMetadataViolationException>());
      expect(
        thrown,
        isNot(isA<ArgumentError>()),
        reason:
            'a catch of ArgumentError on the connection-closing paths would '
            'take a programming mistake for a hostile peer',
      );
      expect(
        thrown,
        isA<RpcException>(),
        reason: 'and it must be findable by the one catch that means rpc_dart',
      );
      expect(
        (thrown! as RpcStatusException).statusCode,
        RpcStatus.invalidArgument,
      );
    });

    // GUARD: the narrowing is only worth anything if a FOREIGN ArgumentError is
    // now distinguishable. This is the distinction the backstops were given.
    test('a foreign ArgumentError is not a metadata violation', () {
      expect(
        ArgumentError('some ordinary bug'),
        isNot(isA<RpcMetadataViolationException>()),
      );
      expect(ArgumentError('some ordinary bug'), isNot(isA<RpcException>()));
    });

    // WITNESS: every frame failure reached a peer as INTERNAL, because
    // RpcFrameException extended RpcException and wireStatusFor's second branch
    // hardcodes INTERNAL. The three kinds are not one answer — and the split is
    // not invented here, it is the one `_answerFramingViolation` already makes.
    test('a frame failure carries the status for its KIND', () {
      // A limit the peer can correct by sending less. RESOURCE_EXHAUSTED is
      // retryable where INTERNAL is final, so this inverts retry semantics for
      // the four sites that use it.
      expect(
        RpcFrameException.limit('payload too large: 9 (max: 4)').statusCode,
        RpcStatus.resourceExhausted,
      );
      // Deterministic, so it must be retried never.
      expect(
        RpcFrameException.policy('metadata violates the policy').statusCode,
        RpcStatus.invalidArgument,
      );
      // The DEFAULT, and it must stay INTERNAL: six malformed-framing sites use
      // it, and platform_error_redaction_test pins that its message is
      // forwarded rather than redacted.
      expect(
        RpcFrameException('bad frame header').statusCode,
        RpcStatus.internal,
      );
    });

    // GUARD: a frame failure is still library-authored, so its diagnostic still
    // reaches the peer. That is what lets a sender correct itself, and it is
    // the reason these types are in the hierarchy at all.
    test('a frame failure still forwards its message', () {
      final limit = wireStatusFor(
        RpcFrameException.limit('payload too large: 9 (max: 4)'),
      );
      expect(limit.status, RpcStatus.resourceExhausted);
      expect(limit.message, contains('max: 4'));
      expect(limit.message, isNot(kInternalErrorWireMessage));
    });

    // GUARD: the rendered text is unchanged, so logs and golden output do not
    // move. The breaker keeps its retryAfter in toString() for this reason.
    test('toString is unchanged', () {
      expect(
        RpcCancelledException('why').toString(),
        'RpcCancelledException: why',
      );
      expect(
        RpcCircuitBreakerOpenException(
          retryAfter: Duration(milliseconds: 250),
        ).toString(),
        'RpcCircuitBreakerOpenException: circuit is open, retry after 250ms',
      );
      expect(
        RpcCircuitBreakerOpenException().toString(),
        'RpcCircuitBreakerOpenException: circuit is open',
      );
    });

    // WITNESS for the base going abstract: a bare `RpcException(msg)` was the
    // lazy path, and wireStatusFor had to answer it INTERNAL — so any site that
    // did not classify itself became INTERNAL on the wire, including limits a
    // peer could correct and methods that do not exist. It cannot be
    // constructed now; a subclass must choose.
    test('the base cannot be thrown without choosing a kind', () {
      // Still the type to CATCH — that half must not have been lost.
      expect(
        _LibraryAuthored('x'),
        isA<RpcException>(),
        reason:
            'abstract must not stop `e is RpcException` from meaning "ours"',
      );
      // And the second wireStatusFor branch still serves such a subclass.
      final wire = wireStatusFor(_LibraryAuthored('a library diagnostic'));
      expect(wire.status, RpcStatus.internal);
      expect(wire.message, contains('a library diagnostic'));
    });
  });
}

/// An [RpcException] that is NOT an [RpcStatusException].
///
/// Every subclass inside core now carries a status, so this stands in for the
/// ones outside it — `RpcDataError`, `RpcWebSocketNonBinaryFrame` — which keep
/// wireStatusFor's second branch reachable.
final class _LibraryAuthored extends RpcException {
  _LibraryAuthored(super.message);
}
