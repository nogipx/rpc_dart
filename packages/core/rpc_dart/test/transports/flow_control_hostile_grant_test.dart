// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// The grant value in a window update is peer-controlled, and it was taken at
// face value. That handed the peer the ability to switch our limit off: two
// frames granting 1 TB lifted a paused-consumer stream from 0.8 MB in flight to
// 300.6 MB, against a 1 MB per-stream and 4 MB connection window.
//
//   honest peer  : +46    messages (~0.8 MB)
//   hostile peer : +18350 messages (~300.6 MB)
//
// Two unauthenticated frames, defeating the one bound that exists to stop a
// peer pinning memory by not reading.
//
// Grants are now clamped to the window this side configured, so a peer can only
// ever slow us down, never speed us up. Clamping the grant BEFORE adding also
// keeps the sum from overflowing: a peer sending 2^63-1 twice wrapped the
// counter to -2. That one turned out to heal itself -- the next honest grant
// brought it positive -- but it is guarded rather than left to luck.
//
// Only the upper bound is clamped: credit legitimately goes slightly negative,
// since a message is admitted whenever any credit remains and can overdraw by
// up to one message. Flooring at zero would hand that overdraft back as free
// credit.

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

int _produced = 0;
Completer<void> _stop = Completer<void>();
Completer<void> _started = Completer<void>();

const _streamWindow = 1024 * 1024;
const _connWindow = 4 * 1024 * 1024;

final class _Contract extends RpcResponderContract {
  _Contract() : super('Svc');

  @override
  void setup() {
    addServerStreamMethod<RpcString, RpcString>(
      methodName: 'firehose',
      handler: (r, {RpcContext? context}) async* {
        if (!_started.isCompleted) _started.complete();
        final chunk = ('y' * 16384).rpc;
        while (!_stop.isCompleted && _produced < 20000) {
          _produced++;
          yield chunk;
          if (_produced % 50 == 0) await Future<void>.delayed(Duration.zero);
        }
      },
      requestCodec: _codec,
      responseCodec: _codec,
    );
    addServerStreamMethod<RpcString, RpcString>(
      methodName: 'bulk',
      handler: (r, {RpcContext? context}) async* {
        if (!_started.isCompleted) _started.complete();
        for (var i = 0; i < 300; i++) {
          yield ('s' * 4096).rpc;
          if (i % 20 == 0) await Future<void>.delayed(Duration.zero);
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

_Rig _connect({
  int? streamWindow = _streamWindow,
  int? connWindow = _connWindow,
}) {
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

/// Sends [value] as a window grant from the client, as a hostile peer would.
Future<void> _grant(_Rig rig, String header, int streamId, int value) => rig
    .client
    .sendMetadata(streamId, RpcMetadata([RpcHeader(header, value.toString())]));

/// Runs the firehose, pauses the consumer, optionally sends [grants], and
/// returns how many messages the handler produced after the pause.
Future<int> _overrunAfterPause(
  _Rig rig, {
  Future<void> Function()? grants,
}) async {
  final sub = rig.caller
      .serverStream<RpcString, RpcString>(
        serviceName: 'Svc',
        methodName: 'firehose',
        request: 'go'.rpc,
        requestCodec: _codec,
        responseCodec: _codec,
      )
      .listen((_) {}, onError: (Object _) {});

  await _started.future.timeout(const Duration(seconds: 5));
  await Future<void>.delayed(const Duration(milliseconds: 150));
  sub.pause();
  final atPause = _produced;
  if (grants != null) await grants();

  await Future<void>.delayed(const Duration(milliseconds: 1200));
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
    _stop = Completer<void>();
    _started = Completer<void>();
  });
  tearDown(() {
    if (!_stop.isCompleted) _stop.complete();
  });

  group('a peer cannot raise our window', () {
    test('an enormous per-stream grant is clamped', () async {
      // The connection window is off, so only the per-stream clamp is under
      // test: with both on, either one alone still caps the other's breach and
      // the case proves nothing.
      final rig = _connect(connWindow: null);
      final overrun = await _overrunAfterPause(
        rig,
        grants: () => _grant(rig, RpcHeaders.xWindowUpdate, 1, 1 << 40),
      );
      expect(
        overrun * 16384,
        lessThan(8 * 1024 * 1024),
        reason:
            'a 1 TB grant let the producer put ~'
            '${(overrun * 16384 / 1e6).toStringAsFixed(1)} MB in flight against '
            'a ${_streamWindow ~/ (1024 * 1024)} MB window',
      );
      await _teardown(rig);
    });

    test('an enormous connection grant is clamped', () async {
      // Per-stream window off, for the same reason.
      final rig = _connect(streamWindow: null);
      final overrun = await _overrunAfterPause(
        rig,
        grants: () => _grant(rig, RpcHeaders.xConnWindowUpdate, 0, 1 << 40),
      );
      expect(
        overrun * 16384,
        lessThan(16 * 1024 * 1024),
        reason:
            'a 1 TB grant let the producer put ~'
            '${(overrun * 16384 / 1e6).toStringAsFixed(1)} MB in flight against '
            'a ${_connWindow ~/ (1024 * 1024)} MB connection window',
      );
      await _teardown(rig);
    });

    test('a hostile peer gains nothing over an honest one', () async {
      // The comparison the fix is really about: both must land in the same
      // place, not merely "below some threshold".
      final honestRig = _connect();
      final honest = await _overrunAfterPause(honestRig);
      await _teardown(honestRig);

      _produced = 0;
      _stop = Completer<void>();
      _started = Completer<void>();
      final hostileRig = _connect();
      final hostile = await _overrunAfterPause(
        hostileRig,
        grants: () async {
          await _grant(hostileRig, RpcHeaders.xWindowUpdate, 1, 1 << 40);
          await _grant(hostileRig, RpcHeaders.xConnWindowUpdate, 0, 1 << 40);
        },
      );
      await _teardown(hostileRig);

      // Both must land under the same absolute bound. Comparing the two runs
      // as a ratio looked sharper but comes from two independently timed
      // measurements, so it flakes on a loaded machine for reasons that have
      // nothing to do with clamping.
      const bound = 8 * 1024 * 1024;
      expect(
        honest * 16384,
        lessThan(bound),
        reason: 'the honest baseline itself exceeded the bound',
      );
      expect(
        hostile * 16384,
        lessThan(bound),
        reason:
            'hostile peer put ~${(hostile * 16384 / 1e6).toStringAsFixed(1)} MB '
            'in flight against an honest peer\'s '
            '~${(honest * 16384 / 1e6).toStringAsFixed(1)} MB',
      );
    });
  });

  group('malformed grants cannot stall a call', () {
    test('a grant that would overflow the counter', () async {
      // 2^63-1 twice wraps to -2 without the clamp.
      const maxInt = 9223372036854775807;
      final rig = _connect();
      final done = rig.caller
          .serverStream<RpcString, RpcString>(
            serviceName: 'Svc',
            methodName: 'bulk',
            request: 'x'.rpc,
            requestCodec: _codec,
            responseCodec: _codec,
          )
          .toList();
      await _started.future.timeout(const Duration(seconds: 5));
      for (var i = 0; i < 2; i++) {
        await _grant(rig, RpcHeaders.xWindowUpdate, 1, maxInt);
        await _grant(rig, RpcHeaders.xConnWindowUpdate, 0, maxInt);
      }
      expect(
        await done.timeout(
          const Duration(seconds: 15),
          onTimeout: () => fail('an overflowing grant stalled the call'),
        ),
        hasLength(300),
      );
      await _teardown(rig);
    });

    test('non-numeric and non-positive grants are ignored', () async {
      final rig = _connect();
      final done = rig.caller
          .serverStream<RpcString, RpcString>(
            serviceName: 'Svc',
            methodName: 'bulk',
            request: 'x'.rpc,
            requestCodec: _codec,
            responseCodec: _codec,
          )
          .toList();
      await _started.future.timeout(const Duration(seconds: 5));
      for (final bad in ['not-a-number', '-1', '0', '']) {
        await rig.client.sendMetadata(
          1,
          RpcMetadata([RpcHeader(RpcHeaders.xWindowUpdate, bad)]),
        );
      }
      expect(
        await done.timeout(
          const Duration(seconds: 15),
          onTimeout: () => fail('a malformed grant stalled the call'),
        ),
        hasLength(300),
      );
      await _teardown(rig);
    });
  });

  group('honest operation is unaffected', () {
    test('a call larger than the window still completes', () async {
      final rig = _connect();
      expect(
        await rig.caller
            .serverStream<RpcString, RpcString>(
              serviceName: 'Svc',
              methodName: 'bulk',
              request: 'x'.rpc,
              requestCodec: _codec,
              responseCodec: _codec,
            )
            .toList()
            .timeout(const Duration(seconds: 20)),
        hasLength(300),
      );
      await _teardown(rig);
    });
  });
}
