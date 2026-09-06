// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// maxActiveStreams bounds live stream STATE, not concurrent handler execution.
// A handler that ignores its cancellation token cannot be preempted, so when a
// stream is reclaimed after its deadline the state goes and the work stays --
// and the admission slot goes back in the pool while the handler runs on.
//
// Measured against maxActiveStreams: 4, one call every 250ms with a 40ms
// deadline into a handler that ignores cancellation:
//
//   maxConcurrentHandlers unset : 37 concurrent handlers after 20s, growing
//   maxConcurrentHandlers 4     :  4
//
// and invisible while it happened: activeResponders read 3 and activeStreams 0
// at the moment 37 handlers were running.
//
// maxActiveStreams is set high in every test here, so a refusal can only come
// from the handler ceiling -- with both at the same value either one alone
// still caps the other's breach and the case proves nothing.

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

/// Per-test state as an object, so a handler leaked by an earlier test writes
/// to its own dead instance instead of this one's counters.
class _Svc extends RpcResponderContract {
  _Svc() : super('Svc');

  int entered = 0;
  int running = 0;
  int peak = 0;
  Completer<void> release = Completer<void>();

  @override
  void setup() {
    // A handler that does NOT watch its token -- the ordinary case for one that
    // calls a database or an HTTP service.
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'work',
      handler: (request, {RpcContext? context}) async {
        entered++;
        running++;
        if (running > peak) peak = running;
        try {
          await release.future;
          return 'r'.rpc;
        } finally {
          running--;
        }
      },
      requestCodec: _codec,
      responseCodec: _codec,
    );
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'quick',
      handler: (request, {RpcContext? context}) async {
        entered++;
        return 'q'.rpc;
      },
      requestCodec: _codec,
      responseCodec: _codec,
    );
    // Yields in a loop rather than parking on a single await, so cancelling the
    // consumer lands on a yield boundary and the generator can actually stop --
    // a generator blocked inside an await is NOT interrupted by cancellation,
    // which is the whole reason this limit exists.
    addServerStreamMethod<RpcString, RpcString>(
      methodName: 'feed',
      handler: (request, {RpcContext? context}) async* {
        entered++;
        running++;
        try {
          while (!release.isCompleted) {
            yield 'tick'.rpc;
            await Future<void>.delayed(const Duration(milliseconds: 20));
          }
        } finally {
          running--;
        }
      },
      requestCodec: _codec,
      responseCodec: _codec,
    );
  }
}

typedef _Rig = ({
  RpcCallerEndpoint caller,
  RpcResponderEndpoint responder,
  RpcChannelTransport client,
  RpcChannelTransport server,
  _Svc svc,
});

_Rig _connect({int? maxHandlers}) {
  // The client's ceiling must be the larger one, or ITS limit throws first and
  // the result says nothing about the server.
  final (clientCh, serverCh) = RpcFrameMultiplexedChannel.pair();
  final client = RpcChannelTransport(
    channel: clientCh,
    isClient: true,
    policy: const RpcSecurityPolicy(maxActiveStreams: 10000),
  );
  final server = RpcChannelTransport(
    channel: serverCh,
    isClient: false,
    policy: RpcSecurityPolicy(
      maxActiveStreams: 1000,
      maxConcurrentHandlers: maxHandlers,
    ),
  );
  final caller = RpcCallerEndpoint(transport: client);
  final responder = RpcResponderEndpoint(transport: server);
  final svc = _Svc();
  responder.registerServiceContract(svc);
  responder.start();
  return (
    caller: caller,
    responder: responder,
    client: client,
    server: server,
    svc: svc,
  );
}

Future<void> _teardown(_Rig rig) async {
  if (!rig.svc.release.isCompleted) rig.svc.release.complete();
  await rig.caller.close();
  await rig.responder.close();
  await rig.client.close();
  await rig.server.close();
}

/// Calls `work` and returns the gRPC status it failed with, or null on success.
Future<int?> _call(
  _Rig rig, {
  Duration? deadline,
  String method = 'work',
}) async {
  try {
    await rig.caller.unaryRequest<RpcString, RpcString>(
      serviceName: 'Svc',
      methodName: method,
      request: 'x'.rpc,
      requestCodec: _codec,
      responseCodec: _codec,
      context: deadline == null ? null : RpcContext.withTimeout(deadline),
    );
    return null;
  } on RpcStatusException catch (e) {
    return e.statusCode;
  } catch (_) {
    return -1;
  }
}

void main() {
  test('a handler keeps its slot after its call is abandoned', () async {
    // The defect: the client's deadline ends the call and the stream is
    // reclaimed, but the handler runs on. Counting streams, the server looks
    // idle and admits the next caller.
    final rig = _connect(maxHandlers: 2);
    addTearDown(() => _teardown(rig));

    final abandoned = [
      _call(rig, deadline: const Duration(milliseconds: 50)),
      _call(rig, deadline: const Duration(milliseconds: 50)),
    ];
    await Future.wait(abandoned);
    // Past the responder's reclaim grace: by now the streams really are gone.
    await Future<void>.delayed(const Duration(milliseconds: 2500));

    expect(
      (await rig.responder.health()).endpointStatus.details['activeResponders'],
      0,
      reason: 'the streams must be gone, or this tests the stream ceiling',
    );
    expect(rig.svc.running, 2, reason: 'both handlers are still running');

    expect(
      await _call(rig),
      RpcStatus.resourceExhausted,
      reason: 'two handlers still hold the only two slots',
    );
    expect(
      rig.svc.entered,
      2,
      reason: 'the refused call must not reach a handler at all',
    );
  });

  test('a simultaneous burst cannot outrun the ceiling', () async {
    // The slot is charged at ADMISSION for exactly this: charging it on handler
    // entry lets a whole batch in before anything is running, and the ceiling
    // never sees it. Measured that way over http2, 30 concurrent calls all got
    // in against a limit of 3.
    final rig = _connect(maxHandlers: 3);
    addTearDown(() => _teardown(rig));

    final calls = [for (var i = 0; i < 30; i++) _call(rig)];
    await Future<void>.delayed(const Duration(milliseconds: 400));

    expect(rig.svc.peak, lessThanOrEqualTo(3));
    expect(
      calls.length - rig.svc.entered,
      greaterThan(0),
      reason: 'the rest must be refused, not queued',
    );

    rig.svc.release.complete();
    await Future.wait(calls);
  });

  test('the slot is released when the handler finishes', () async {
    // The other half. A bound that is charged but never released still stops
    // the attack, so the witness above stays green while the ceiling ratchets
    // down onto ordinary traffic.
    final rig = _connect(maxHandlers: 2);
    addTearDown(() => _teardown(rig));

    final blocked = [_call(rig), _call(rig)];
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(rig.svc.running, 2);
    expect(await _call(rig), RpcStatus.resourceExhausted);

    rig.svc.release.complete();
    await Future.wait(blocked);
    await Future<void>.delayed(const Duration(milliseconds: 100));

    expect(rig.svc.running, 0);
    expect(
      await _call(rig, method: 'quick'),
      isNull,
      reason: 'the slots came back, so a new call must be admitted',
    );
  });

  test('sustained ordinary traffic is unaffected', () async {
    // 30 sequential calls through a ceiling of 2. Each releases before the next
    // arrives, so nothing may be refused -- a leaked slot shows up here as the
    // third call onwards failing.
    final rig = _connect(maxHandlers: 2);
    addTearDown(() => _teardown(rig));

    for (var i = 0; i < 30; i++) {
      expect(
        await _call(rig, method: 'quick'),
        isNull,
        reason: 'call $i was refused; a slot is leaking',
      );
    }
    expect(rig.svc.entered, 30);
  });

  test('a streaming handler holds its slot for the whole call', () async {
    // The stream variant releases from a generator's finally, so it must also
    // fire when the CONSUMER cancels rather than when the handler returns.
    final rig = _connect(maxHandlers: 1);
    addTearDown(() => _teardown(rig));

    final sub = rig.caller
        .serverStream<RpcString, RpcString>(
          serviceName: 'Svc',
          methodName: 'feed',
          request: 'go'.rpc,
          requestCodec: _codec,
          responseCodec: _codec,
        )
        .listen((_) {}, onError: (Object _) {});
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(rig.svc.running, 1);

    expect(
      await _call(rig, method: 'quick'),
      RpcStatus.resourceExhausted,
      reason: 'the open stream holds the only slot',
    );

    await sub.cancel();
    await Future<void>.delayed(const Duration(milliseconds: 300));

    expect(
      await _call(rig, method: 'quick'),
      isNull,
      reason: 'cancelling the consumer must release the slot too',
    );
  });

  test('GUARD: unset is the previous behaviour', () async {
    // Opt-in by design: turning it on converts "runs slowly" into "rejects
    // calls". With it unset the pileup is still reachable, which is what makes
    // this a policy choice rather than a fix applied to everyone.
    final rig = _connect();
    addTearDown(() => _teardown(rig));

    for (var i = 0; i < 4; i++) {
      unawaited(_call(rig));
    }
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(rig.svc.running, 4);
    expect(await _call(rig, method: 'quick'), isNull);
  });

  group('policy plumbing', () {
    test('the default is no limit', () {
      expect(const RpcSecurityPolicy().maxConcurrentHandlers, isNull);
    });

    test('survives a map round-trip', () {
      const policy = RpcSecurityPolicy(maxConcurrentHandlers: 17);
      expect(
        RpcSecurityPolicy.fromMap(policy.toMap()).maxConcurrentHandlers,
        17,
      );
    });

    test('unset round-trips as unset', () {
      const policy = RpcSecurityPolicy();
      expect(
        RpcSecurityPolicy.fromMap(policy.toMap()).maxConcurrentHandlers,
        isNull,
      );
    });
  });
}
