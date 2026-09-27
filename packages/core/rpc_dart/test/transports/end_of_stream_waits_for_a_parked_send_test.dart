// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// An end-of-stream carries no payload, so nothing meters it. `finishSending`
// knows that: it marks the stream finished and then AWAITS a credit-parked
// send before the end goes out. `sendMetadata(endStream: true)` ends a stream
// too, and did neither -- so a trailer could overtake a DATA frame still parked
// for credit, and the peer counted a frame short while the sender believed it
// had sent everything. Round 366 got that failure from a real user over a
// socket: `Declared length 2442197 does not match received 524288 bytes`.
//
// `sendDirectObject(endStream: true)` is the third such path (round 445) and
// the sharpest: a direct object takes no credit at all, so it needed no race.
//
// Each witness is paired with `finishSending` on the SAME pair kind: that one
// carried the rule first, so if a control fails, flow control is not parking
// and its witness proves nothing.
//
// Parking needs only credit arithmetic, not a real socket -- `tryConsume`
// refuses on `credit <= 0`. What a real socket is needed for is measuring how
// LONG a park lasts, which is not what this asserts.

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

/// Small enough that one frame exhausts it. The gate admits on `credit > 0`,
/// not on whether the message FITS, so the FIRST frame passes and drives the
/// credit negative; the SECOND is the one that parks.
const _policy = RpcSecurityPolicy(
  flowControlWindowBytes: 512,
  flowControlConnectionWindowBytes: 512,
  initialSendWindowBytes: 512,
);

/// What the peer saw, in the order it saw it.
///
/// [zeroCopy] picks `memoryPair` over `pair`: only that one carries
/// `sendDirectObject`, and `pair` answers it with `UnsupportedError`, which
/// reads like a passing arm.
Future<List<String>> _observe(
  Future<void> Function(RpcChannelTransport client, int streamId) ending, {
  bool zeroCopy = false,
}) async {
  final (client, server) = zeroCopy
      ? RpcChannelTransport.memoryPair(policy: _policy)
      : RpcChannelTransport.pair(policy: _policy);
  final seen = <String>[];
  final sawEnd = Completer<void>();

  server.incomingMessages.listen((m) {
    if (m.payload != null) seen.add('data:${m.payload!.length}');
    if (m.directPayload != null) seen.add('direct');
    if (m.isEndOfStream && !sawEnd.isCompleted) {
      seen.add('end');
      sawEnd.complete();
    }
  });

  final id = client.createStream();
  await client.sendMetadata(id, RpcMetadata.forClientRequest('S', 'M'));

  // Passes (credit is 512 and > 0), leaving the window exhausted.
  await client.sendMessage(id, Uint8List(600));

  // Parks: credit is now negative. Deliberately NOT awaited -- the whole point
  // is what happens to an ending issued while this one is still waiting.
  final parked = client.sendMessage(id, Uint8List(16));

  await ending(client, id);
  await sawEnd.future.timeout(const Duration(seconds: 3), onTimeout: () {});

  await client.close();
  await server.close();
  parked.ignore();
  return seen;
}

void main() {
  group('an ending waits for a send parked on credit', () {
    // WITNESS. Without the fix the end arrives while the 16-byte frame is
    // still parked, so `seen` is [data:600, end] and the peer is a frame short.
    test('sendMetadata(endStream: true) does not overtake it', () async {
      final seen = await _observe(
        (c, id) => c.sendMetadata(
          id,
          RpcMetadata.forTrailer(RpcStatus.ok),
          endStream: true,
        ),
      );

      expect(
        seen.indexOf('end'),
        greaterThan(seen.indexOf('data:16')),
        reason:
            'the trailer was written while a DATA frame was parked for '
            'credit, so the peer ends the stream a frame short while the '
            'sender believes it sent everything: $seen',
      );
    });

    // WITNESS. `sendDirectObject` ends a stream too and meters NOTHING -- a
    // direct object never takes credit -- so without the rule it needs no race
    // at all: `seen` is [data:600, direct, end, data:16], the end ahead of the
    // frame the sender is still waiting to place.
    test('sendDirectObject(endStream: true) does not overtake it', () async {
      final seen = await _observe(
        (c, id) => c.sendDirectObject(id, 'payload', endStream: true),
        zeroCopy: true,
      );

      expect(
        seen.indexOf('end'),
        greaterThan(seen.indexOf('data:16')),
        reason:
            'the direct object ended the stream while a DATA frame was parked '
            'for credit, so the peer ends a frame short: $seen',
      );
    });

    // CONTROL. The sibling that already had the rule. If this fails too, the
    // window is not parking anything and the witness above proves nothing.
    test(
      'CONTROL: finishSending already waits, and is the proof it can',
      () async {
        final seen = await _observe((c, id) => c.finishSending(id));

        expect(
          seen.indexOf('end'),
          greaterThan(seen.indexOf('data:16')),
          reason:
              'finishSending is the guarded path; if this fails, flow '
              'control is not parking and neither case measures anything: $seen',
        );
      },
    );

    // CONTROL for the zero-copy witness, which runs on a DIFFERENT pair. Its
    // "held back" would otherwise be readable as a property of `memoryPair`
    // rather than of the rule.
    test('CONTROL: finishSending waits on the zero-copy pair too', () async {
      final seen = await _observe(
        (c, id) => c.finishSending(id),
        zeroCopy: true,
      );

      expect(
        seen.indexOf('end'),
        greaterThan(seen.indexOf('data:16')),
        reason:
            'if this fails, memoryPair is not parking and the '
            'sendDirectObject case measures nothing: $seen',
      );
    });
  });
}
