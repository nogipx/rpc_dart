// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// Per-stream windows bound one call; nothing bounded their sum, so a peer just
// opened more streams. Measured with 100 concurrent server streams whose
// consumers all paused, each holding a 1 MB window, counting what the handlers
// produced after the pause:
//
//   no connection window : +10223 messages (~167.5 MB in flight)
//   connection window  2 MB : +320  (~5.2 MB)
//   connection window  8 MB : +576  (~9.4 MB)
//   connection window 32 MB : +1343 (~22.0 MB)
//
// At the default per-stream window of 4 MB and ceiling of 4096 streams, the
// total a peer could pin was ~17 GB.
//
// Two things this cost to get right:
//
//   * A waiter must live in exactly one list. Parking a sender in both a
//     per-stream and a connection-level list leaked one completer per blocked
//     send, since waking through either left the stale entry in the other. It
//     showed up as memory growing as the window SHRANK (2 MB retained 168 MB
//     against 32 MB retaining 24 MB), because a smaller window parks more.
//   * The connection window is advertised eagerly, at construction. Waiting for
//     the first inbound frame left a full round trip during which the peer was
//     unbounded, and with many streams opening at once that startup burst was
//     most of the traffic: ~64 MB in flight against a 2 MB window.

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

int _produced = 0;
Completer<void> _stop = Completer<void>();

final class _Contract extends RpcResponderContract {
  _Contract() : super('Svc');

  @override
  void setup() {
    addServerStreamMethod<RpcString, RpcString>(
      methodName: 'firehose',
      handler: (r, {RpcContext? context}) async* {
        final chunk = ('y' * 16384).rpc;
        var n = 0;
        while (!_stop.isCompleted && n < 3000) {
          n++;
          _produced++;
          yield chunk;
          if (n % 50 == 0) await Future<void>.delayed(Duration.zero);
        }
      },
      requestCodec: _codec,
      responseCodec: _codec,
    );
    addServerStreamMethod<RpcString, RpcString>(
      methodName: 'bulk',
      handler: (r, {RpcContext? context}) async* {
        for (var i = 0; i < 200; i++) {
          yield ('s' * 4096).rpc;
        }
      },
      requestCodec: _codec,
      responseCodec: _codec,
    );
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'unary',
      handler: (r, {RpcContext? context}) async => 'u:${r.value}'.rpc,
      requestCodec: _codec,
      responseCodec: _codec,
    );
  }
}

typedef _Rig = ({
  RpcChannelTransport client,
  RpcChannelTransport server,
  RpcCallerEndpoint caller,
  RpcResponderEndpoint responder,
});

_Rig _connect({required int? connWindow, int? streamWindow = 1024 * 1024}) {
  final policy = RpcSecurityPolicy(
    flowControlWindowBytes: streamWindow,
    flowControlConnectionWindowBytes: connWindow,
  );
  final (client, server) = RpcChannelTransport.pair(policy: policy);
  final caller = RpcCallerEndpoint(transport: client);
  final responder = RpcResponderEndpoint(transport: server);
  responder.registerServiceContract(_Contract());
  responder.start();
  return (client: client, server: server, caller: caller, responder: responder);
}

Future<void> _teardown(_Rig r) async {
  await r.caller.close();
  await r.responder.close();
  await r.client.close();
  await r.server.close();
}

/// Polls until [condition] holds, up to [timeout]. The unbounded witnesses need
/// this: asserting "the producer got far ahead" after a fixed sleep measures
/// CPU speed, which collapses on a loaded test runner.
Future<void> _waitUntil(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 15),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition() && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

/// Opens [streams] firehoses, pauses them all, and returns how many messages
/// the handlers produced after the pause.
Future<int> _overrunAcross(
  _Rig rig,
  int streams, {
  bool Function(int)? until,
}) async {
  final subs = <StreamSubscription<RpcString>>[];
  for (var i = 0; i < streams; i++) {
    subs.add(
      rig.caller
          .serverStream<RpcString, RpcString>(
            serviceName: 'Svc',
            methodName: 'firehose',
            request: 'go'.rpc,
            requestCodec: _codec,
            responseCodec: _codec,
          )
          .listen((_) {}, onError: (Object _) {}),
    );
  }
  await Future<void>.delayed(const Duration(milliseconds: 300));
  for (final sub in subs) {
    sub.pause();
  }
  final atPause = _produced;
  if (until == null) {
    await Future<void>.delayed(const Duration(milliseconds: 1500));
  } else {
    await _waitUntil(() => until(_produced - atPause));
  }
  final overrun = _produced - atPause;

  _stop.complete();
  for (final sub in subs) {
    sub.resume();
  }
  await Future<void>.delayed(const Duration(milliseconds: 200));
  for (final sub in subs) {
    await sub.cancel();
  }
  return overrun;
}

void main() {
  setUp(() {
    _produced = 0;
    _stop = Completer<void>();
  });
  tearDown(() {
    if (!_stop.isCompleted) _stop.complete();
  });

  group('concurrent streams share one bound', () {
    test('the total is bounded, not just each stream', () async {
      // 40 streams x 1 MB per-stream window = 40 MB if only the per-stream
      // bound applied; the connection pool is 4 MB.
      final rig = _connect(connWindow: 4 * 1024 * 1024);
      final overrun = await _overrunAcross(rig, 40);
      expect(
        overrun * 16384,
        lessThan(20 * 1024 * 1024),
        reason:
            '40 paused streams held ~'
            '${(overrun * 16384 / 1e6).toStringAsFixed(1)} MB in flight '
            'against a 4 MB connection window',
      );
      await _teardown(rig);
    });

    test('without it the total scales with the stream count', () async {
      final rig = _connect(connWindow: null);
      final overrun = await _overrunAcross(
        rig,
        40,
        until: (n) => n * 16384 > 30 * 1024 * 1024,
      );
      expect(
        overrun * 16384,
        greaterThan(30 * 1024 * 1024),
        reason: 'per-stream windows alone should let 40 streams pin ~40 MB',
      );
      await _teardown(rig);
    });

    test('a smaller pool holds less, not more', () async {
      // Directly guards the waiter-leak regression, whose signature was memory
      // growing as the window shrank.
      final small = _connect(connWindow: 2 * 1024 * 1024);
      final smallOverrun = await _overrunAcross(small, 30);
      await _teardown(small);

      _produced = 0;
      _stop = Completer<void>();
      final large = _connect(connWindow: 16 * 1024 * 1024);
      final largeOverrun = await _overrunAcross(large, 30);
      await _teardown(large);

      expect(
        smallOverrun,
        lessThan(largeOverrun),
        reason:
            'a 2 MB pool held $smallOverrun messages and a 16 MB pool held '
            '$largeOverrun: the bound is inverted, which is what a leaked '
            'waiter per blocked send looks like',
      );
    });
  });

  group('nothing deadlocks on the shared pool', () {
    test('calls larger than the whole pool still complete', () async {
      final rig = _connect(connWindow: 128 * 1024, streamWindow: 64 * 1024);
      final got = await rig.caller
          .serverStream<RpcString, RpcString>(
            serviceName: 'Svc',
            methodName: 'bulk',
            request: 'x'.rpc,
            requestCodec: _codec,
            responseCodec: _codec,
          )
          .toList()
          .timeout(const Duration(seconds: 20));
      expect(got, hasLength(200), reason: '800 KB through a 128 KB pool');
      await _teardown(rig);
    });

    test('many concurrent calls sharing a tiny pool', () async {
      final rig = _connect(connWindow: 128 * 1024, streamWindow: 64 * 1024);
      await Future.wait([
        for (var i = 0; i < 20; i++)
          rig.caller
              .serverStream<RpcString, RpcString>(
                serviceName: 'Svc',
                methodName: 'bulk',
                request: 'x'.rpc,
                requestCodec: _codec,
                responseCodec: _codec,
              )
              .drain<void>(),
      ]).timeout(
        const Duration(seconds: 30),
        onTimeout: () => fail('concurrent calls deadlocked on the pool'),
      );
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(rig.caller.collectEndpointMetrics()['pendingRequests'], 0);
      expect(rig.responder.collectEndpointMetrics()['openStreams'], 0);
      await _teardown(rig);
    });

    test('a unary call is unaffected', () async {
      final rig = _connect(connWindow: 128 * 1024, streamWindow: 64 * 1024);
      expect(
        (await rig.caller
                .unaryRequest<RpcString, RpcString>(
                  serviceName: 'Svc',
                  methodName: 'unary',
                  request: 'x'.rpc,
                  requestCodec: _codec,
                  responseCodec: _codec,
                )
                .timeout(const Duration(seconds: 10)))
            .value,
        'u:x',
      );
      await _teardown(rig);
    });
  });

  group('policy plumbing', () {
    test('the connection header is protocol-reserved', () {
      expect(RpcHeaders.isReserved(RpcHeaders.xConnWindowUpdate), isTrue);
    });

    test('the default is a finite pool', () {
      expect(
        const RpcSecurityPolicy().flowControlConnectionWindowBytes,
        isNotNull,
      );
    });

    test('survives a map round-trip', () {
      const policy = RpcSecurityPolicy(flowControlConnectionWindowBytes: 999);
      expect(
        RpcSecurityPolicy.fromMap(
          policy.toMap(),
        ).flowControlConnectionWindowBytes,
        999,
      );
    });

    test('a disabled pool round-trips as disabled', () {
      const policy = RpcSecurityPolicy(flowControlConnectionWindowBytes: null);
      expect(
        RpcSecurityPolicy.fromMap(
          policy.toMap(),
        ).flowControlConnectionWindowBytes,
        isNull,
      );
    });
  });
}
