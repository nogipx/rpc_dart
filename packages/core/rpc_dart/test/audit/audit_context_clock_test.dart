// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// Regression guard (audit C7): RpcContext deadline checks go through an
// injectable clock, so isExpired / remainingTime / withTimeout are testable
// without real time. Default clock is DateTime.now (behavior unchanged).

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

void main() {
  group('C7: RpcContext injectable clock', () {
    test('isExpired and remainingTime follow the injected clock', () {
      var now = DateTime.utc(2026, 1, 1, 12);
      final ctx = RpcContext.empty()
          .withClock(() => now)
          .withTimeout(const Duration(seconds: 10));

      expect(ctx.isExpired, isFalse);
      expect(ctx.remainingTime, const Duration(seconds: 10));

      // Advance the fake clock past the deadline — no real waiting.
      now = now.add(const Duration(seconds: 11));
      expect(ctx.isExpired, isTrue);
      expect(ctx.remainingTime, Duration.zero);
    });

    test('the clock survives context copies (withX propagation)', () {
      var now = DateTime.utc(2026, 1, 1);
      final ctx = RpcContext.empty()
          .withClock(() => now)
          .withTimeout(const Duration(seconds: 5))
          .withTraceId('t')
          .withValue('k', 'v');

      expect(ctx.isExpired, isFalse);
      now = now.add(const Duration(seconds: 6));
      expect(ctx.isExpired, isTrue);
    });

    test('default clock is the real DateTime.now', () {
      final ctx = RpcContext.withTimeout(const Duration(seconds: 30));
      expect(ctx.isExpired, isFalse);
      expect(ctx.remainingTime!.inSeconds, greaterThan(25));
    });
  });
}
