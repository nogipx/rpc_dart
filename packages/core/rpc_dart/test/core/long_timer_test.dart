// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// On the web a Dart Timer becomes setTimeout, whose delay is a SIGNED 32-BIT
// millisecond value -- 2,147,483,647 ms, about 24.86 days. dart2js passes the
// duration straight through and every JS runtime clamps an overflowing delay to
// 1 ms rather than rejecting it, so a timer set for a month fires at once.
//
// Measured with identical source on both platforms, asking whether an
// RpcCallScope had closed 120 ms after being handed each deadline:
//
//   deadline    VM       dart2js (before)   dart2js (after)
//   1 hour      open     open               open
//   24 days     open     open               open
//   25 days     open     CLOSED             open
//   30 days     open     CLOSED             open
//   1 year      open     CLOSED             open
//
// and `grpc-timeout: 720H` -- a legal, peer-supplied 30-day value -- landed in
// the broken half, so a peer could make a web client or server cancel its own
// call the instant it started. Node named every offending value:
//
//   TimeoutOverflowWarning: 2592000000 does not fit into a 32-bit signed
//   integer. Timeout duration was set to 1.
//
// Nine such warnings before the fix, zero after.
//
// NOTE ON COVERAGE: the failing half of that table only reproduces on dart2js,
// and `dart test -p node` could not run in the environment where this was
// found, so the web side was measured by compiling the probe with
// `dart compile js` and running it under node directly. On the VM the
// assertions below are GUARDS; on the web they are the witnesses.

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

/// Just past setTimeout's ceiling: the smallest duration that used to break.
const _overCeiling = Duration(milliseconds: RpcLongTimer.maxChunkMillis + 1);

void main() {
  group('RpcLongTimer', () {
    // WITNESS on the web: this is the duration that fired in 1 ms.
    test('a duration past the JS ceiling does not fire early', () async {
      var fired = false;
      final timer = RpcLongTimer(_overCeiling, () => fired = true);

      await Future<void>.delayed(const Duration(milliseconds: 150));

      expect(
        fired,
        isFalse,
        reason:
            'a timer set for ${_overCeiling.inDays} days fired within 150ms; '
            'on the web setTimeout clamped the overflowing delay to 1ms',
      );
      expect(timer.isActive, isTrue);
      timer.cancel();
    });

    test('a month-long duration does not fire early', () async {
      var fired = false;
      final timer = RpcLongTimer(const Duration(days: 30), () => fired = true);

      await Future<void>.delayed(const Duration(milliseconds: 150));

      expect(fired, isFalse);
      timer.cancel();
    });

    // GUARD: chunking must not break an ordinary short timer.
    test('a short duration still fires, once', () async {
      var fired = 0;
      RpcLongTimer(const Duration(milliseconds: 30), () => fired++);

      await Future<void>.delayed(const Duration(milliseconds: 200));

      expect(fired, 1);
    });

    // GUARD: cancel has to reach the currently-armed chunk.
    test('cancel stops a long timer', () async {
      var fired = false;
      final timer = RpcLongTimer(const Duration(days: 30), () => fired = true);
      timer.cancel();

      await Future<void>.delayed(const Duration(milliseconds: 100));

      expect(fired, isFalse);
      expect(timer.isActive, isFalse);
    });

    test('cancel stops a short timer before it fires', () async {
      var fired = false;
      final timer = RpcLongTimer(
        const Duration(milliseconds: 80),
        () => fired = true,
      );
      timer.cancel();

      await Future<void>.delayed(const Duration(milliseconds: 200));

      expect(fired, isFalse);
    });

    // GUARD: the common case must not pay for the rare one.
    test('create() returns a plain Timer under the ceiling', () {
      final t = RpcLongTimer.create(const Duration(seconds: 1), () {});
      expect(t, isNot(isA<RpcLongTimer>()));
      t.cancel();
    });

    test('create() returns a chunking timer over the ceiling', () {
      final t = RpcLongTimer.create(_overCeiling, () {});
      expect(t, isA<RpcLongTimer>());
      t.cancel();
    });
  });

  group('deadlines built on it', () {
    // WITNESS on the web, end to end: this is what a peer could trigger.
    test('a 30-day call scope is not closed immediately', () async {
      final scope = RpcCallScope(
        context: RpcContext.withDeadline(
          DateTime.now().add(const Duration(days: 30)),
        ),
      );

      await Future<void>.delayed(const Duration(milliseconds: 150));

      expect(
        scope.isClosed,
        isFalse,
        reason: 'a 30-day deadline cancelled the call at once',
      );
      await scope.close();
    });

    // WITNESS on the web: the peer-supplied form of the same value.
    test('a peer grpc-timeout of 720H does not close the scope', () async {
      final remaining = RpcMetadata.parseGrpcTimeout('720H');
      expect(remaining, isNotNull);

      final scope = RpcCallScope(
        context: RpcContext.withDeadline(DateTime.now().add(remaining!)),
      );

      await Future<void>.delayed(const Duration(milliseconds: 150));

      expect(scope.isClosed, isFalse);
      await scope.close();
    });

    // GUARD: a deadline that really has passed must still close the scope, and
    // an ordinary short one must still fire.
    test('an already-expired deadline still closes the scope', () async {
      final scope = RpcCallScope(
        context: RpcContext.withDeadline(
          DateTime.now().subtract(const Duration(seconds: 1)),
        ),
      );

      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(scope.isClosed, isTrue);
    });

    test('a short deadline still closes the scope', () async {
      final scope = RpcCallScope(
        context: RpcContext.withTimeout(const Duration(milliseconds: 40)),
      );

      await Future<void>.delayed(const Duration(milliseconds: 200));

      expect(scope.isClosed, isTrue);
    });
  });
}
