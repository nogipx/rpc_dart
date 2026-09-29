// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// RpcChannelTransport tracks _finishedStreams purely to keep finishSending()
// idempotent, but the set was pruned ONLY when a terminal inbound frame arrived
// for that stream id. A call that never gets one -- timed out, cancelled, or
// cut off by a dropped connection -- left its entry behind forever, so on a
// long-lived connection the set grew once per abandoned call and never shrank.
// Explicit teardown via releaseStreamId() now prunes it.

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

Future<int> _finishedStreams(RpcChannelTransport transport) async {
  final health = await transport.health();
  return health.details['finishedStreams']! as int;
}

void main() {
  final codec = RpcCodec(RpcString.fromJson);

  test('abandoned calls do not accumulate finished-stream entries', () async {
    // No responder is bound, so every call times out without a reply and the
    // transport never sees an inbound end-of-stream for those ids.
    final (client, server) = RpcChannelTransport.pair();

    expect(await _finishedStreams(client), 0);

    for (var i = 0; i < 5; i++) {
      final caller = UnaryCaller<RpcString, RpcString>(
        transport: client,
        serviceName: 'S',
        methodName: 'M',
        requestCodec: codec,
        responseCodec: codec,
      );
      await expectLater(
        caller.call('x'.rpc, timeout: const Duration(milliseconds: 20)),
        throwsA(anything),
      );
    }

    // POLLED, because the release is now chained onto a cancellation notice.
    //
    // Round 498 made a timed-out unary call TELL the server before releasing its
    // id, and that notice rides a frame with `endStream: true` — which marks the
    // stream finished on the way out. The release that prunes the entry is
    // chained onto the notice (round 448's ordering: notice first, release after,
    // bounded), so immediately after the call returns there is one entry still
    // in flight. It is not accumulation: five abandoned calls read 1, not 5.
    //
    // What this test is for — the set returns to zero rather than growing once
    // per abandoned call — is unchanged, so the assertion is unchanged and only
    // the instrument waits.
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (await _finishedStreams(client) > 0 &&
        DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(
      await _finishedStreams(client),
      0,
      reason: 'each abandoned call leaked one entry before the fix',
    );

    await client.close();
    await server.close();
  });

  test('finishSending stays idempotent for a live stream', () async {
    final (client, server) = RpcChannelTransport.pair();

    final received = <bool>[];
    server.incomingMessages.listen((m) => received.add(m.isEndOfStream));

    final streamId = client.createStream();
    await client.sendMetadata(streamId, RpcMetadata.forClientRequest('S', 'M'));
    await client.finishSending(streamId);
    await client.finishSending(streamId); // must not send a second marker
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(received.where((eos) => eos).length, 1);

    await client.close();
    await server.close();
  });
}
