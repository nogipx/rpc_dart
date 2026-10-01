// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// `_runDrain` polled every 50 ms, so a server whose last call finished a
// millisecond into the drain still waited for the next tick. That is shutdown
// latency paid on every deploy for work already done.
//
// It is now signalled: `_cleanupStream` completes a waiter when the active-stream
// count reaches zero, and the budget is a Timer rather than a `DateTime.now()`
// comparison, so a wall-clock step cannot change it.
//
// The bounds below are deliberately loose. The point is the difference between
// "waits for a tick" and "does not", which is an order of magnitude, so the
// assertions have room to survive a loaded machine rather than pinning a number.
//
// The measurements are in `.claude/loop/rounds/514`.

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

Completer<void>? _release;

final class _Slow extends RpcResponderContract {
  _Slow() : super('Slow');

  @override
  void setup() {
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'wait',
      requestCodec: _codec,
      responseCodec: _codec,
      handler: (req, {context}) async {
        await _release!.future;
        return 'done'.rpc;
      },
    );
  }
}

typedef _Rig = ({
  RpcCallerEndpoint caller,
  RpcResponderEndpoint responder,
  Future<Object> call,
});

/// Starts one call and waits for it to reach the handler, so a drain has
/// something to wait for.
Future<_Rig> _callInFlight() async {
  _release = Completer<void>();
  final (client, server) = RpcChannelTransport.pair();
  final responder = RpcResponderEndpoint(transport: server)
    ..registerServiceContract(_Slow())
    ..start();
  final caller = RpcCallerEndpoint(transport: client);

  final call = caller
      .unaryRequest<RpcString, RpcString>(
        serviceName: 'Slow',
        methodName: 'wait',
        request: 'x'.rpc,
        requestCodec: _codec,
        responseCodec: _codec,
        context: RpcContext.empty().withTimeout(const Duration(seconds: 10)),
      )
      .then<Object>((r) => r)
      .catchError((Object e) => e);

  await Future<void>.delayed(const Duration(milliseconds: 60));
  addTearDown(() async {
    if (!_release!.isCompleted) _release!.complete();
    await call;
    await caller.close();
    await responder.close();
  });
  return (caller: caller, responder: responder, call: call);
}

/// Drains with one call in flight, releasing the handler after [releaseAfter],
/// and returns how long the drain took in milliseconds.
Future<int> _drainReleasingAfter(Duration releaseAfter) async {
  final rig = await _callInFlight();

  final sw = Stopwatch()..start();
  final draining = rig.responder.drain(timeout: const Duration(seconds: 5));
  Future<void>.delayed(releaseAfter, () {
    if (!_release!.isCompleted) _release!.complete();
  });
  await draining;
  sw.stop();
  return sw.elapsedMilliseconds;
}

void main() {
  test(
    'WITNESS: a drain ends when the work does, not on the next tick',
    () async {
      // Two releases, both inside ONE 50 ms poll interval, and the reading is the
      // DIFFERENCE between the two drains.
      //
      // Polled: both land on the same tick, so both drains take ~50 ms and the
      // difference is ~0. Signalled: each drain ends when its own release does, so
      // the difference tracks the gap between them. An absolute ceiling here does
      // not survive a loaded machine — it read 92 ms against a 35 ms bound at
      // `--concurrency=32` — while the poll tick is a wall-clock Timer that does
      // not stretch with contention, so the DISCRIMINATOR holds even when both
      // numbers inflate.
      //
      // BEST of several attempts, because the two releases have to sit inside one
      // tick for that to work, which caps the signal at ~48 ms — and at enough
      // oversubscription scheduling noise reaches it. Polling cannot produce the
      // gap on ANY attempt, so taking the largest costs the test nothing.
      var widest = 0;
      final attempts = <String>[];
      for (var i = 0; i < 3; i++) {
        final early = await _drainReleasingAfter(
          const Duration(milliseconds: 2),
        );
        final late = await _drainReleasingAfter(
          const Duration(milliseconds: 30),
        );
        attempts.add('${early}ms/${late}ms');
        if (late - early > widest) widest = late - early;
        if (widest >= 18) break;
      }

      expect(
        widest,
        greaterThanOrEqualTo(18),
        reason:
            'drains took ${attempts.join(', ')} for releases 28 ms apart: a '
            'polled drain quantises both to the same 50 ms tick, so this '
            'difference collapsing to zero is the regression',
      );
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );

  group('GUARD', () {
    test(
      'a drain still waits for a handler that is genuinely slow',
      () async {
        // Without this, a drain that returned immediately and tore down in-flight
        // calls would pass the witness — which is the one thing drain exists to
        // prevent.
        final rig = await _callInFlight();

        final sw = Stopwatch()..start();
        final draining = rig.responder.drain(
          timeout: const Duration(seconds: 5),
        );
        Future<void>.delayed(const Duration(milliseconds: 120), () {
          if (!_release!.isCompleted) _release!.complete();
        });
        await draining;
        sw.stop();

        expect(
          sw.elapsedMilliseconds,
          greaterThanOrEqualTo(100),
          reason: 'the drain must not abandon a call that is still running',
        );
      },
      timeout: const Timeout(Duration(seconds: 30)),
    );

    test(
      'a drain with nothing in flight returns promptly',
      () async {
        final (client, server) = RpcChannelTransport.pair();
        final responder = RpcResponderEndpoint(transport: server)
          ..registerServiceContract(_Slow())
          ..start();
        final caller = RpcCallerEndpoint(transport: client);
        addTearDown(() async {
          await caller.close();
          await responder.close();
        });

        final sw = Stopwatch()..start();
        await responder.drain(timeout: const Duration(seconds: 5));
        sw.stop();
        expect(sw.elapsedMilliseconds, lessThan(35));
      },
      timeout: const Timeout(Duration(seconds: 30)),
    );

    test(
      'the budget still expires when the handler never finishes',
      () async {
        // The completer must not replace the deadline: a handler that never
        // returns has to be forced, or a deploy hangs.
        final rig = await _callInFlight();

        final sw = Stopwatch()..start();
        await rig.responder.drain(timeout: const Duration(milliseconds: 200));
        sw.stop();

        expect(sw.elapsedMilliseconds, greaterThanOrEqualTo(180));
        expect(
          sw.elapsedMilliseconds,
          lessThan(2000),
          reason: 'the budget must bound the wait, not be ignored',
        );
      },
      timeout: const Timeout(Duration(seconds: 30)),
    );

    test(
      'concurrent drains share one completion',
      () async {
        // `drain()` memoises the in-flight future; the completer must not break
        // that, or a second caller walks past and tears down what the first was
        // protecting.
        final rig = await _callInFlight();

        final a = rig.responder.drain(timeout: const Duration(seconds: 5));
        final b = rig.responder.drain(timeout: const Duration(seconds: 5));
        Future<void>.delayed(const Duration(milliseconds: 10), () {
          if (!_release!.isCompleted) _release!.complete();
        });
        await Future.wait([a, b]);
      },
      timeout: const Timeout(Duration(seconds: 30)),
    );
  });
}
