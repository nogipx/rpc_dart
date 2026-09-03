// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// RpcCallScope.close() wraps every disposer in a try/catch and logs whatever
// throws. A disposer registered AFTER close never reached that loop: it ran
// through a bare `Future.microtask(callback)` whose returned future was
// dropped, so a cleanup that failed became an unhandled async error.
//
// In the root zone -- where a server's main() runs -- that is fatal. Measured
// with the SAME failing disposer either side of close():
//
//   registered BEFORE close : 0 escaped unhandled errors
//   registered AFTER  close : 1   (via onDispose, use() and listen() alike)
//
// and a root-zone reproduction terminated the process outright:
//
//   start
//   Unhandled exception:
//   Bad state: rollback failed
//   #1  new Future.microtask.<anonymous closure> (dart:async/future.dart:287:40)
//
// -- the line after it never printed.
//
// Reachable without any misuse. A deadline closes the scope while the handler
// is still running (Dart cannot preempt a plain async function), and the
// handler then registers its rollback in a `finally`, exactly as RpcCallScope's
// own documentation shows. One failing rollback took the server down.

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

/// Runs [body] and returns how many errors escaped as unhandled async errors.
///
/// This is the mechanism under test: an escaped error here is one that would
/// have reached the root zone's fatal handler in a real server.
Future<int> escapedErrors(Future<void> Function() body) async {
  var escaped = 0;
  final settled = Completer<void>();
  await runZonedGuarded(
    () async {
      await body();
      // Give any dropped future a chance to surface before we count.
      await Future<void>.delayed(const Duration(milliseconds: 60));
      if (!settled.isCompleted) settled.complete();
    },
    (error, stack) {
      escaped++;
      if (!settled.isCompleted) settled.complete();
    },
  );
  await settled.future;
  await Future<void>.delayed(const Duration(milliseconds: 20));
  return escaped;
}

void main() {
  group('a disposer that fails after the scope closed', () {
    // WITNESS
    test('does not escape as an unhandled async error', () async {
      final escaped = await escapedErrors(() async {
        final scope = RpcCallScope();
        await scope.close();
        scope.onDispose(() async => throw StateError('rollback failed'));
      });

      expect(
        escaped,
        0,
        reason:
            'a failing late disposer escaped $escaped time(s); in the root '
            'zone that terminates the server process',
      );
    });

    // WITNESS: use() is the documented acquire/release helper.
    test('does not escape when registered through use()', () async {
      final escaped = await escapedErrors(() async {
        final scope = RpcCallScope();
        await scope.close();
        scope.use('handle', (h) async => throw StateError('release failed'));
      });

      expect(escaped, 0);
    });

    // WITNESS: listen()'s disposer is a bare sub.cancel(), which runs user code.
    test('does not escape when a late listen() cancel throws', () async {
      final escaped = await escapedErrors(() async {
        final scope = RpcCallScope();
        await scope.close();
        final ctl = StreamController<int>(
          onCancel: () async => throw StateError('cancel failed'),
        );
        scope.listen(ctl.stream, (_) {});
      });

      expect(escaped, 0);
    });

    // WITNESS: the shape that makes this reachable in a real server.
    test('does not escape when a deadline closed the scope first', () async {
      final escaped = await escapedErrors(() async {
        final scope = RpcCallScope(
          context: RpcContext.withTimeout(const Duration(milliseconds: 20)),
        );
        // The handler is still running when the deadline fires.
        await Future<void>.delayed(const Duration(milliseconds: 60));
        expect(
          scope.isClosed,
          isTrue,
          reason: 'the deadline should have fired',
        );
        // ...and registers its rollback in a finally, as the docs show.
        scope.onDispose(() async => throw StateError('rollback failed'));
      });

      expect(
        escaped,
        0,
        reason:
            'a handler that outlived its deadline killed the process through '
            'its own cleanup',
      );
    });
  });

  group('the surrounding behaviour is unchanged', () {
    // GUARD: the pre-close path was always safe and must stay so.
    test('a failing disposer before close still does not escape', () async {
      final escaped = await escapedErrors(() async {
        final scope = RpcCallScope();
        scope.onDispose(() async => throw StateError('cleanup failed'));
        await scope.close();
      });

      expect(escaped, 0);
    });

    // GUARD: catching the failure must not stop the cleanup from RUNNING --
    // best-effort late disposal is the documented behaviour, and a resource
    // still needs releasing.
    test('a late disposer still runs', () async {
      var ran = 0;
      final scope = RpcCallScope();
      await scope.close();
      scope.onDispose(() {
        ran++;
      });
      await Future<void>.delayed(const Duration(milliseconds: 40));

      expect(ran, 1, reason: 'the late disposer was skipped, not just guarded');
    });

    // GUARD: a late disposer that FAILS must still have run.
    test('a late disposer that throws still ran', () async {
      var ran = 0;
      await escapedErrors(() async {
        final scope = RpcCallScope();
        await scope.close();
        scope.onDispose(() async {
          ran++;
          throw StateError('boom');
        });
      });

      expect(ran, 1);
    });

    // GUARD: ordinary LIFO disposal is untouched.
    test('disposers still run in LIFO order', () async {
      final order = <int>[];
      final scope = RpcCallScope();
      scope.onDispose(() => order.add(1));
      scope.onDispose(() => order.add(2));
      scope.onDispose(() => order.add(3));
      await scope.close();

      expect(order, [3, 2, 1]);
    });
  });
}
