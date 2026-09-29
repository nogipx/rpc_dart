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

void main() {
  test(
    'WITNESS: a drain ends when the work does, not on the next tick',
    () async {
      final rig = await _callInFlight();

      final sw = Stopwatch()..start();
      final draining = rig.responder.drain(timeout: const Duration(seconds: 5));
      Future<void>.delayed(const Duration(milliseconds: 1), () {
        if (!_release!.isCompleted) _release!.complete();
      });
      await draining;
      sw.stop();

      expect(
        sw.elapsedMilliseconds,
        lessThan(35),
        reason:
            'the handler finished after 1 ms; polling every 50 ms made the drain '
            'take ~52 ms for work that was already done',
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
