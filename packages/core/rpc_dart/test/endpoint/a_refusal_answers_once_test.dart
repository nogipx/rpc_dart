// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// A call opened with metadata AND payload is TWO frames, and a refusal ran
// through `_detached`, so the id was remembered a microtask later than the second
// frame arrived. Both frames found no stream, both fell through the same checks,
// and both were answered:
//
//   draining, a NEW call (2 frames)    [status=14, status=14]
//   ceiling 1, a 2nd call (2 frames)   [status=8,  status=8]
//
// Two terminal statuses on one stream — a protocol violation anywhere the peer
// keeps stream state, and the same damage class round 454 fixed for the
// closed-stream case by a different mechanism.
//
// `[14]` and `[14, 14]` read the same to a `contains` matcher, which is why every
// assertion here counts.

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

final class _Svc extends RpcResponderContract {
  _Svc() : super('Svc');

  @override
  void setup() {
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'echo',
      handler: (request, {RpcContext? context}) async => request,
      requestCodec: _codec,
      responseCodec: _codec,
    );
  }
}

typedef _Rig = ({
  RpcChannelTransport client,
  RpcResponderEndpoint responder,
  List<String> answers,
});

/// A caller with no ceiling of its own against a responder with [maxStreams].
///
/// The policies are separate on purpose: one shared policy would give the CLIENT
/// the ceiling too, and its own `createStream` would refuse before the responder
/// ever saw the call.
_Rig _rig({int maxStreams = 4096}) {
  final (clientCh, serverCh) = RpcFrameMultiplexedChannel.pair();
  final client = RpcChannelTransport(channel: clientCh, isClient: true);
  final server = RpcChannelTransport(
    channel: serverCh,
    isClient: false,
    policy: RpcSecurityPolicy(maxActiveStreams: maxStreams),
  );
  final responder = RpcResponderEndpoint(transport: server);
  responder.registerServiceContract(_Svc());
  responder.start();

  final answers = <String>[];
  client.incomingMessages.listen((m) {
    final status = m.metadata?.getHeaderValue(RpcHeaders.grpcStatus);
    if (status != null) answers.add(status);
  });

  addTearDown(() async {
    await responder.close().catchError((Object _) {});
    await client.close().catchError((Object _) {});
    await server.close().catchError((Object _) {});
  });

  return (client: client, responder: responder, answers: answers);
}

/// Opens one call as a peer does: metadata, then payload. Two frames.
Future<void> _openCall(RpcChannelTransport client) async {
  final id = client.createStream();
  await client.sendMetadata(id, RpcMetadata.forClientRequest('Svc', 'echo'));
  await client.sendMessage(
    id,
    RpcMessageFrame.encode(_codec.serialize('hi'.rpc)),
    endStream: true,
  );
  await Future<void>.delayed(const Duration(milliseconds: 300));
}

void main() {
  // WITNESS. Without the synchronous remember this is [14, 14].
  test('a drain refusal answers ONCE for a two-frame call', () async {
    final rig = _rig();
    rig.responder.markDraining();

    await _openCall(rig.client);

    expect(
      rig.answers,
      [RpcStatus.unavailable.toString()],
      reason:
          'one call, one terminal status, however many frames it arrived in',
    );
  });

  // WITNESS for the sibling refusal, which the lead asked to be counted before
  // anything was fixed: it has the same shape and was never driven.
  test('a ceiling refusal answers ONCE for a two-frame call', () async {
    final rig = _rig(maxStreams: 1);

    // Occupy the only slot. A metadata frame with no payload never dispatches,
    // so the state stays live and holds the slot.
    final held = rig.client.createStream();
    await rig.client.sendMetadata(
      held,
      RpcMetadata.forClientRequest('Svc', 'echo'),
    );
    await Future<void>.delayed(const Duration(milliseconds: 150));
    rig.answers.clear();

    await _openCall(rig.client);

    expect(rig.answers, [RpcStatus.resourceExhausted.toString()]);
  });

  // GUARD. Answering once must not become answering zero: both refusals are
  // load-bearing, and a fix that silenced them would pass a "not twice" test.
  test('GUARD: both refusals still REFUSE', () async {
    final draining = _rig();
    draining.responder.markDraining();
    await _openCall(draining.client);
    expect(draining.answers, isNotEmpty, reason: 'the drain refusal is gone');

    final atCeiling = _rig(maxStreams: 1);
    final held = atCeiling.client.createStream();
    await atCeiling.client.sendMetadata(
      held,
      RpcMetadata.forClientRequest('Svc', 'echo'),
    );
    await Future<void>.delayed(const Duration(milliseconds: 150));
    atCeiling.answers.clear();
    await _openCall(atCeiling.client);
    expect(
      atCeiling.answers,
      isNotEmpty,
      reason: 'the ceiling refusal is gone',
    );
  });

  // GUARD. An ordinary call is untouched — one answer, and it is the handler's.
  test(
    'GUARD: a healthy call still gets exactly one answer, and it is OK',
    () async {
      final rig = _rig();

      await _openCall(rig.client);

      expect(rig.answers, [RpcStatus.ok.toString()]);
    },
  );
}
