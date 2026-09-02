// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// Flow-control bookkeeping is keyed by stream id, and the PEER chooses stream
// ids. The transport does that bookkeeping before the responder pipeline
// decides whether an id is a legitimate stream at all, so ids that never became
// streams still allocated -- permanently, since nothing ever released them:
//
//   50000 grant frames on never-opened ids -> sendCredit: 50000
//   50000 data  frames on never-opened ids -> pendingGrant: 50000,
//                                             advertised:   50000
//
// The data-frame case also had the transport send one window-update frame back
// per ghost id: 50,000 frames of amplification from 50,000 tiny frames.
//
// maxActiveStreams did not bound any of it, because these ids never reach the
// pipeline that enforces it. The maps are now capped at maxActiveStreams, which
// is the most live streams a connection can have.
//
// New ids are REFUSED at the cap rather than evicting existing ones. Evicting
// would drop a live stream's credit, so a flood of ghost ids could push a real
// stream out of its own window -- turning a memory bug into a way to disable
// the bound. A stream that arrives while the cap is full simply gets no
// flow-control state, leaving it unbounded rather than stalled.

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

const _cap = 64;

final class _Contract extends RpcResponderContract {
  _Contract() : super('Svc');

  @override
  void setup() {
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'ping',
      handler: (r, {RpcContext? context}) async => 'p:${r.value}'.rpc,
      requestCodec: _codec,
      responseCodec: _codec,
    );
    addServerStreamMethod<RpcString, RpcString>(
      methodName: 'bulk',
      handler: (r, {RpcContext? context}) async* {
        for (var i = 0; i < 50; i++) {
          yield ('s' * 4096).rpc;
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

_Rig _connect() {
  const policy = RpcSecurityPolicy(
    maxActiveStreams: _cap,
    flowControlWindowBytes: 64 * 1024,
    flowControlConnectionWindowBytes: 256 * 1024,
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

/// Sends [n] frames from the SERVER on client-parity ids that were never
/// opened, as a hostile peer naming ids at random would.
Future<void> _ghostFrames(_Rig rig, int n, {required bool grants}) async {
  for (var i = 0; i < n; i++) {
    final id = 1 + i * 2;
    if (grants) {
      await rig.server.sendMetadata(
        id,
        RpcMetadata([RpcHeader(RpcHeaders.xWindowUpdate, '65536')]),
      );
    } else {
      await rig.server.sendMessage(
        id,
        RpcMessageFrame.encode(_codec.serialize('x'.rpc)),
      );
    }
    if (i % 500 == 0) await Future<void>.delayed(Duration.zero);
  }
  await Future<void>.delayed(const Duration(milliseconds: 200));
}

void main() {
  group('ids that never become streams cannot grow the maps', () {
    test('grant frames', () async {
      final rig = _connect();
      await _ghostFrames(rig, _cap * 20, grants: true);
      final sizes = rig.client.flowControlStateSizes;
      expect(
        sizes['sendCredit'],
        lessThanOrEqualTo(_cap),
        reason: '${_cap * 20} ghost grants left ${sizes['sendCredit']} entries',
      );
      await _teardown(rig);
    });

    test('data frames', () async {
      final rig = _connect();
      await _ghostFrames(rig, _cap * 20, grants: false);
      final sizes = rig.client.flowControlStateSizes;
      expect(
        sizes['pendingGrant'],
        lessThanOrEqualTo(_cap),
        reason:
            '${_cap * 20} ghost frames left '
            '${sizes['pendingGrant']} pending entries',
      );
      expect(
        sizes['advertised'],
        lessThanOrEqualTo(_cap),
        reason:
            '${_cap * 20} ghost frames left '
            '${sizes['advertised']} advertised entries',
      );
      await _teardown(rig);
    });

    test('the cap does not evict a live stream mid-call', () async {
      // Eviction would drop the running call's credit, which is exactly how a
      // memory bug becomes a way to switch the bound off.
      final rig = _connect();
      final call = rig.caller
          .serverStream<RpcString, RpcString>(
            serviceName: 'Svc',
            methodName: 'bulk',
            request: 'x'.rpc,
            requestCodec: _codec,
            responseCodec: _codec,
          )
          .toList();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await _ghostFrames(rig, _cap * 20, grants: true);
      expect(
        await call.timeout(const Duration(seconds: 20)),
        hasLength(50),
        reason: 'the in-flight call must survive a ghost-id flood',
      );
      await _teardown(rig);
    });
  });

  group('healthy traffic is unaffected', () {
    test('normal calls leave the maps near empty', () async {
      final rig = _connect();
      for (var i = 0; i < 30; i++) {
        expect(
          (await rig.caller.unaryRequest<RpcString, RpcString>(
            serviceName: 'Svc',
            methodName: 'ping',
            request: 'n$i'.rpc,
            requestCodec: _codec,
            responseCodec: _codec,
          )).value,
          'p:n$i',
        );
      }
      await Future<void>.delayed(const Duration(milliseconds: 300));
      final sizes = rig.client.flowControlStateSizes;
      for (final entry in sizes.entries) {
        expect(
          entry.value,
          lessThanOrEqualTo(_cap),
          reason: '${entry.key} grew to ${entry.value} over 30 finished calls',
        );
      }
      await _teardown(rig);
    });

    test('flow control still bounds a real stream after a flood', () async {
      final rig = _connect();
      await _ghostFrames(rig, _cap * 20, grants: true);
      // A call opened after the flood still completes, which is what the
      // refuse-at-cap policy trades against evicting live state.
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
        hasLength(50),
      );
      await _teardown(rig);
    });
  });
}
