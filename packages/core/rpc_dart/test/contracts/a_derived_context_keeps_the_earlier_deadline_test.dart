// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// A context derived for a downstream call cannot outlive its parent.
//
// `forward(timeout:)` and `RpcContextBuilder.inheritFrom(...).withTimeout`
// keep the earlier of the parent's deadline and the new one, as gRPC and Go
// do on derivation. `forward()` is the helper for a downstream call: the
// deadline, token and trace carry over and credentials do not.
// `RpcContext.withTimeout` on a context replaces: that is the explicit way to
// set one.

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

final _now = DateTime.utc(2026, 10, 10, 12);
DateTime _clock() => _now;

RpcContext _parent({Duration left = const Duration(milliseconds: 200)}) =>
    RpcContext.empty().withClock(_clock).withTimeout(left);

void main() {
  group('WITNESS: a derived context keeps the earlier deadline', () {
    test('forward(timeout:) longer than what is left', () {
      final parent = _parent();
      final child = parent.forward(timeout: const Duration(seconds: 2));
      expect(child.deadline, parent.deadline);
    });

    test('inheritFrom(...).withTimeout longer than what is left', () {
      final parent = _parent();
      final child = RpcContextBuilder.inheritFrom(
        parent,
      ).withTimeout(const Duration(seconds: 2)).build();
      expect(child.deadline, parent.deadline);
    });

    test('inheritFrom(...).withDeadline later than the parent', () {
      final parent = _parent();
      final child = RpcContextBuilder.inheritFrom(
        parent,
      ).withDeadline(_now.add(const Duration(seconds: 2))).build();
      expect(child.deadline, parent.deadline);
    });
  });

  group('GUARD: a shorter deadline still applies', () {
    test('forward(timeout:) shorter than what is left', () {
      final parent = _parent(left: const Duration(seconds: 2));
      final child = parent.forward(timeout: const Duration(milliseconds: 100));
      expect(child.deadline, _now.add(const Duration(milliseconds: 100)));
    });

    test('a parent with no deadline takes the child timeout', () {
      final parent = RpcContext.empty().withClock(_clock);
      final child = parent.forward(timeout: const Duration(seconds: 1));
      expect(child.deadline, _now.add(const Duration(seconds: 1)));
    });
  });

  group('GUARD: setting a deadline explicitly still replaces it', () {
    test('RpcContext.withTimeout', () {
      final ctx = _parent().withTimeout(const Duration(seconds: 2));
      expect(ctx.deadline, _now.add(const Duration(seconds: 2)));
    });

    test('RpcContextBuilder.from(...).withTimeout', () {
      final ctx = RpcContextBuilder.from(
        _parent(),
      ).withTimeout(const Duration(seconds: 2)).build();
      expect(ctx.deadline, _now.add(const Duration(seconds: 2)));
    });
  });

  group('forward()', () {
    final token = RpcCancellationToken();
    final incoming = _parent()
        .withCancellation(token)
        .withTraceId('trace-1')
        .withAdditionalHeaders({
          'authorization': 'Bearer secret',
          'x-api-key': 'key',
          'cookie': 'c=1',
          'x-tenant': 'acme',
        });
    final out = incoming.forward();

    test('keeps the deadline, the token and the trace', () {
      expect(out.deadline, incoming.deadline);
      expect(identical(out.cancellationToken, token), isTrue);
      expect(out.traceId, 'trace-1');
    });

    test('mints a new request id', () {
      expect(out.requestId, isNot(incoming.requestId));
    });

    test('drops the credentials and keeps the other headers', () {
      expect(out.getHeader('authorization'), isNull);
      expect(out.getHeader('x-api-key'), isNull);
      expect(out.getHeader('cookie'), isNull);
      expect(out.getHeader('x-tenant'), 'acme');
    });

    test('cannot extend the deadline either', () {
      final longer = incoming.forward(timeout: const Duration(seconds: 2));
      expect(longer.deadline, incoming.deadline);
    });
  });
}
