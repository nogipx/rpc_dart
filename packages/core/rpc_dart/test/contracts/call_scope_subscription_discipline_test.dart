// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// Three defects the B-56 sweep found, all in the same mechanic: drive a
// USER-SUPPLIED stream into a call.
//
// The criterion that makes them one class is ownership. A stream the library
// built cannot park on cancel; one handed in by a user -- or built from a
// user's `async*` -- can, and that is the whole reason L-16 exists.
//
//   RpcCallScope.listen   AWAITED the cancel, via `onDispose(sub.cancel)`.
//                         Disposers are awaited with `disposerTimeout` as the
//                         only bound, so closing a scope with a parked
//                         generator cost up to FIVE SECONDS per subscription.
//                         `track`, thirty lines above, states the rule and its
//                         evidence.
//
//   RpcCallScope.track    forwarded no pause/resume, so a slow consumer never
//   RpcCallScope.listen   slowed the SOURCE.
//
//   the circuit breaker's abandon timer dropped a cancel Future BARE, on a
//                         detached callback -- a rejected cancel is then an
//                         unhandled async error, which in the root zone kills
//                         the isolate.

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

/// A generator that PARKS on cancel, which is what a user's `async*` does when
/// it is suspended at a yield. The library's own controllers cannot do this,
/// which is why only user-supplied streams are in this class.
Stream<int> _parkingOnCancel(Completer<void> cancelled) {
  late StreamController<int> c;
  c = StreamController<int>(
    onListen: () {
      c.add(1);
      c.add(2);
    },
    onCancel: () {
      cancelled.complete();
      // Never completes: the generator refuses to unwind.
      return Completer<void>().future;
    },
  );
  return c.stream;
}

void main() {
  test(
    'close() does not wait out the disposer budget on a parked cancel',
    () async {
      RpcCallScope.disposerTimeout = const Duration(seconds: 5);
      final scope = RpcCallScope();
      final cancelled = Completer<void>();

      scope.listen(_parkingOnCancel(cancelled), (_) {});

      final sw = Stopwatch()..start();
      await scope.close().timeout(
        const Duration(seconds: 10),
        onTimeout: () => fail('close() never returned'),
      );
      sw.stop();

      expect(
        await cancelled.future
            .timeout(const Duration(seconds: 1))
            .then((_) => true)
            .catchError((Object _) => false),
        isTrue,
        reason: 'the cancel must still be ATTEMPTED, just not awaited',
      );
      expect(
        sw.elapsedMilliseconds,
        lessThan(2000),
        reason:
            'close() took ${sw.elapsedMilliseconds}ms: the disposer awaited a '
            'cancel that parks, so it paid the full disposerTimeout',
      );
    },
  );

  // GUARD: not awaiting must not mean not cancelling. An ordinary source is
  // still cancelled, or the fix would be "leak every subscription".
  test('GUARD: an ordinary subscription is still cancelled on close', () async {
    final scope = RpcCallScope();
    final source = StreamController<int>();
    addTearDown(source.close);

    scope.listen(source.stream, (_) {});
    expect(source.hasListener, isTrue);

    await scope.close();
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(source.hasListener, isFalse);
  });

  group('track forwards backpressure to the source', () {
    test('pausing the tracked stream pauses the source', () async {
      final scope = RpcCallScope();
      addTearDown(scope.close);
      final source = StreamController<int>();
      addTearDown(source.close);

      final sub = scope.track(source.stream).listen((_) {});
      await Future<void>.delayed(Duration.zero);
      expect(source.isPaused, isFalse);

      sub.pause();
      await Future<void>.delayed(Duration.zero);

      expect(
        source.isPaused,
        isTrue,
        reason:
            'without onPause forwarding, the controller buffers without bound '
            'while the producer runs flat out',
      );

      sub.resume();
      await Future<void>.delayed(Duration.zero);
      expect(source.isPaused, isFalse);

      await sub.cancel();
    });
  });

  // GUARD: track's cancel discipline, which was already right, stays right.
  test('GUARD: track still cancels without awaiting', () async {
    RpcCallScope.disposerTimeout = const Duration(seconds: 5);
    final scope = RpcCallScope();
    final cancelled = Completer<void>();

    scope.track(_parkingOnCancel(cancelled)).listen((_) {});

    final sw = Stopwatch()..start();
    await scope.close().timeout(const Duration(seconds: 10));
    sw.stop();

    expect(sw.elapsedMilliseconds, lessThan(2000));
  });
}
