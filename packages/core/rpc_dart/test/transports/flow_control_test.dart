// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// Per-stream flow control. Without it a producer is throttled only by a
// consumer that never pauses: measured on a server stream with the consumer
// paused for 2s, the handler ran 19,000 messages ahead, queueing 311 MB.
//
//   flow control OFF : +19000 messages (~311.3 MB)
//   window 1 MB      : +42            (~0.7 MB)
//   window 4 MB      : +208           (~3.4 MB)
//
// Credit rides on bare metadata frames (RpcHeaders.xWindowUpdate), which a peer
// that predates this ignores entirely -- measured in both directions mid-call,
// with every message still delivered and no stream state left behind. There is
// no handshake and no wire-format change: before the peer's first grant proves
// it participates a sender is held to initialSendWindowBytes, and if that is
// spent with the peer still silent for initialSendWindowGrace the window is
// dropped -- so a version mismatch degrades to the old unbounded behaviour
// rather than deadlocking. The mixed-policy test below is that case, and it is
// per LEVEL: that peer grants at connection level and never per stream.
//
// This only bounds anything because the stages above the transport now stop
// pulling for a consumer that has stopped reading (see
// consumer_demand_propagation_test) and because the responder's send queue is
// awaited rather than merely enqueued. Until both were true the metered stream
// was drained regardless and credit flowed forever.

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

int _produced = 0;
Completer<void> _stop = Completer<void>();

/// Runaway guard for the firehose handler, clamped at the pause point rather
/// than fixed on the total. Only what is produced *after* the consumer pauses
/// queues up, so that is the part worth bounding -- and a total cap made the
/// overrun budget depend on how fast the machine ran before the pause, which a
/// fast runner spent entirely there (CI: 6104 of 8000 produced pre-pause, so
/// the unbounded witness could never reach the 2000 it waits for).
int _cap = 1 << 30;

/// 16 KiB per message, so a 1 MB window is ~64 messages.
final _chunk = ('y' * 16384).rpc;

final class _Contract extends RpcResponderContract {
  _Contract() : super('Svc');

  @override
  void setup() {
    addServerStreamMethod<RpcString, RpcString>(
      methodName: 'firehose',
      handler: (r, {RpcContext? context}) async* {
        while (!_stop.isCompleted) {
          _produced++;
          yield _chunk;
          if (_produced % 50 == 0) await Future<void>.delayed(Duration.zero);
          if (_produced >= _cap) break;
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
    addServerStreamMethod<RpcString, RpcString>(
      methodName: 'bulk',
      handler: (r, {RpcContext? context}) async* {
        for (var i = 0; i < 400; i++) {
          yield _chunk;
        }
      },
      requestCodec: _codec,
      responseCodec: _codec,
    );
    addClientStreamMethod<RpcString, RpcString>(
      methodName: 'upload',
      handler: (reqs, {RpcContext? context}) async {
        var n = 0;
        await for (final _ in reqs) {
          n++;
        }
        return 'c:$n'.rpc;
      },
      requestCodec: _codec,
      responseCodec: _codec,
    );
    addBidirectionalMethod<RpcString, RpcString>(
      methodName: 'mirror',
      handler: (reqs, {RpcContext? context}) async* {
        await for (final r in reqs) {
          yield r;
        }
      },
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

_Rig _connect({int? window = 1024 * 1024, int? serverWindow}) {
  final clientPolicy = RpcSecurityPolicy(flowControlWindowBytes: window);
  final serverPolicy = RpcSecurityPolicy(
    flowControlWindowBytes: serverWindow ?? window,
  );
  // Built by hand rather than through pair() so each side can carry a
  // different policy -- that is what the mixed-version case needs.
  final (clientCh, serverCh) = RpcFrameMultiplexedChannel.pair(
    policy: clientPolicy,
  );
  final client = RpcChannelTransport(
    channel: clientCh,
    isClient: true,
    policy: clientPolicy,
  );
  final server = RpcChannelTransport(
    channel: serverCh,
    isClient: false,
    policy: serverPolicy,
  );
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

/// Polls until [condition] holds, up to [timeout]. Used by the unbounded
/// witnesses: asserting "the producer got far ahead" after a fixed sleep
/// measures CPU speed, which collapses under a loaded test runner.
Future<void> _waitUntil(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 15),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition() && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

/// Runs the firehose with the consumer paused, returning messages produced
/// after the pause. When [until] is given, waits for it instead of a fixed
/// window.
Future<int> _overrunAfterPause(_Rig rig, {bool Function(int)? until}) async {
  final sub = rig.caller
      .serverStream<RpcString, RpcString>(
        serviceName: 'Svc',
        methodName: 'firehose',
        request: 'go'.rpc,
        requestCodec: _codec,
        responseCodec: _codec,
      )
      .listen((_) {}, onError: (Object _) {});

  await Future<void>.delayed(const Duration(milliseconds: 150));
  sub.pause();
  final atPause = _produced;
  // Everything from here on is queued, so bound it: comfortably above the 2000
  // the unbounded witness waits for, and well under the 8000 total that used to
  // have to cover the pre-pause run as well.
  _cap = atPause + 2600;
  if (until == null) {
    await Future<void>.delayed(const Duration(milliseconds: 900));
  } else {
    await _waitUntil(() => until(_produced - atPause));
  }
  final overrun = _produced - atPause;

  _stop.complete();
  sub.resume();
  await Future<void>.delayed(const Duration(milliseconds: 200));
  await sub.cancel();
  return overrun;
}

void main() {
  setUp(() {
    _produced = 0;
    _cap = 1 << 30;
    _stop = Completer<void>();
  });
  tearDown(() {
    if (!_stop.isCompleted) _stop.complete();
  });

  group('a paused consumer bounds the remote producer', () {
    test('the producer stops within the window', () async {
      final rig = _connect(window: 1024 * 1024);
      final overrun = await _overrunAfterPause(rig);
      // 1 MB / 16 KiB = 64 messages, plus what was already in flight.
      expect(
        overrun,
        lessThan(400),
        reason:
            'the producer ran $overrun messages (~'
            '${(overrun * 16384 / 1e6).toStringAsFixed(1)} MB) past a paused '
            'consumer with a 1 MB window',
      );
      await _teardown(rig);
    });

    test('a larger window allows proportionally more', () async {
      final rig = _connect(window: 4 * 1024 * 1024);
      final overrun = await _overrunAfterPause(rig);
      expect(overrun, lessThan(1200));
      await _teardown(rig);
    });

    test('disabling it restores the unbounded behaviour', () async {
      // The witness for what this fixes: without a window the same handler
      // runs thousands of messages ahead.
      final rig = _connect(window: null);
      final overrun = await _overrunAfterPause(rig, until: (n) => n > 2000);
      expect(
        overrun,
        greaterThan(2000),
        reason: 'with no window the producer should be unthrottled',
      );
      await _teardown(rig);
    });
  });

  group('no shape can deadlock on its own window', () {
    // Every case pushes far more than the window through, so each one only
    // completes if the sender parks and is woken again.
    test('unary', () async {
      final rig = _connect(window: 64 * 1024);
      final r = await rig.caller
          .unaryRequest<RpcString, RpcString>(
            serviceName: 'Svc',
            methodName: 'unary',
            request: 'x'.rpc,
            requestCodec: _codec,
            responseCodec: _codec,
          )
          .timeout(const Duration(seconds: 10));
      expect(r.value, 'u:x');
      await _teardown(rig);
    });

    test('server stream far exceeding the window', () async {
      final rig = _connect(window: 64 * 1024);
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
      expect(got, hasLength(400), reason: '6.5 MB through a 64 KiB window');
      await _teardown(rig);
    });

    test('client stream far exceeding the window', () async {
      final rig = _connect(window: 64 * 1024);
      final requests = StreamController<RpcString>();
      final call = rig.caller.clientStream<RpcString, RpcString>(
        serviceName: 'Svc',
        methodName: 'upload',
        requestCodec: _codec,
        responseCodec: _codec,
      )(requests.stream);
      for (var i = 0; i < 400; i++) {
        requests.add(_chunk);
      }
      await requests.close();
      expect((await call.timeout(const Duration(seconds: 20))).value, 'c:400');
      await _teardown(rig);
    });

    test('bidirectional far exceeding the window', () async {
      final rig = _connect(window: 64 * 1024);
      final requests = StreamController<RpcString>();
      final done = rig.caller
          .bidirectionalStream<RpcString, RpcString>(
            serviceName: 'Svc',
            methodName: 'mirror',
            requests: requests.stream,
            requestCodec: _codec,
            responseCodec: _codec,
          )
          .toList();
      for (var i = 0; i < 300; i++) {
        requests.add(_chunk);
      }
      await requests.close();
      expect(await done.timeout(const Duration(seconds: 20)), hasLength(300));
      await _teardown(rig);
    });

    test('tearing down while a sender is parked does not hang', () async {
      final rig = _connect(window: 64 * 1024);
      final sub = rig.caller
          .serverStream<RpcString, RpcString>(
            serviceName: 'Svc',
            methodName: 'firehose',
            request: 'go'.rpc,
            requestCodec: _codec,
            responseCodec: _codec,
          )
          .listen((_) {}, onError: (Object _) {});
      await Future<void>.delayed(const Duration(milliseconds: 150));
      sub.pause();
      // By now the server is parked waiting for credit that will never come.
      await Future<void>.delayed(const Duration(milliseconds: 200));
      await _teardown(rig).timeout(
        const Duration(seconds: 10),
        onTimeout: () => fail('teardown hung on a parked sender'),
      );
      _stop.complete();
      await sub.cancel();
    });
  });

  group('interop with a peer that does not participate', () {
    test('a peer that never grants is not starved', () async {
      // Client has per-stream flow control off, so it never advertises a
      // per-stream window. The server must not park forever after its initial
      // send window -- this is the whole reason grants ride on a frame an older
      // peer ignores. It pauses for initialSendWindowGrace and then runs
      // unbounded, which is what the 20s budget below covers.
      //
      // Note the client still advertises the CONNECTION window, so this is also
      // the per-level case: a grant at one level says nothing about the other.
      final rig = _connect(window: null, serverWindow: 1024 * 1024);
      final got = await rig.caller
          .serverStream<RpcString, RpcString>(
            serviceName: 'Svc',
            methodName: 'bulk',
            request: 'x'.rpc,
            requestCodec: _codec,
            responseCodec: _codec,
          )
          .toList()
          .timeout(
            const Duration(seconds: 20),
            onTimeout: () =>
                fail('the server starved against a peer that never grants'),
          );
      expect(got, hasLength(400));
      await _teardown(rig);
    });
  });

  group('policy plumbing', () {
    test('the window header is protocol-reserved', () {
      // A caller able to set it could lift its own peer's limit.
      expect(RpcHeaders.isReserved(RpcHeaders.xWindowUpdate), isTrue);
    });

    test('the default is a finite window', () {
      expect(const RpcSecurityPolicy().flowControlWindowBytes, isNotNull);
    });

    test('survives a map round-trip', () {
      const policy = RpcSecurityPolicy(flowControlWindowBytes: 12345);
      expect(
        RpcSecurityPolicy.fromMap(policy.toMap()).flowControlWindowBytes,
        12345,
      );
    });

    test('a disabled window round-trips as disabled', () {
      const policy = RpcSecurityPolicy(flowControlWindowBytes: null);
      expect(
        RpcSecurityPolicy.fromMap(policy.toMap()).flowControlWindowBytes,
        isNull,
      );
    });

    test('an absent key keeps the default', () {
      expect(
        RpcSecurityPolicy.fromMap(const {}).flowControlWindowBytes,
        const RpcSecurityPolicy().flowControlWindowBytes,
      );
    });
  });
}
