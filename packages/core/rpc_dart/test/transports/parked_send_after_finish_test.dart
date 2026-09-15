// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// An end-of-stream must not sail past a message still waiting for the window.
//
// A send with no credit parks. The end-of-stream that follows carries no
// payload, so nothing meters it, and before this was fixed it went straight out
// — overtaking the message. The peer then saw a stream that finished, counted
// what had arrived, and refused the short blob; the sender was never told
// anything at all, because the parked send was not woken either. Measured
// against a consumer's uploads: the same blob refused fifteen times over, with
// not one reconnect in the logs to explain it.
//
// What a sender is entitled to is narrow, and both halves are tested here:
//
//   * a grant that lands while it waits puts the message out AHEAD of the end,
//     because `finishSending` holds the end back for it;
//   * woken with the window still shut and the stream over, it is REFUSED —
//     never left believing, and never left hanging.
//
// `initialSendWindowBytes` — which creates the parked state in the first place
// — arrived in 6.0.0; 5.0.1 had no such parameter, and that bump is the whole
// difference between the release that worked and the one that did not.

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

/// A window a few messages exhaust, with no grace timer to hand the sender its
/// credit back for free — the grace would rescue the very state under test.
const _policy = RpcSecurityPolicy(
  flowControlWindowBytes: 4096,
  initialSendWindowBytes: 4096,
  initialSendWindowGrace: null,
);

Uint8List _frame(int n) => RpcMessageFrame.encode(Uint8List(n));

/// Spends the window and leaves one send parked on it.
///
/// The gate admits on `credit > 0` rather than on whether the message FITS, so
/// each of the first three is let through and drives the balance negative. The
/// one after that is the one that waits.
Future<Object?> _parkOne(
  RpcChannelTransport client,
  int streamId, {
  required Future<void> Function() thenDo,
}) async {
  await client.sendMessage(streamId, _frame(4000));
  await client.sendMessage(streamId, _frame(4000));
  await client.sendMessage(streamId, _frame(4000));

  Object? outcome;
  final parked = client
      .sendMessage(streamId, _frame(4000))
      .then<void>((_) => outcome = 'written')
      .catchError((Object e) => outcome = e);

  await Future<void>.delayed(const Duration(milliseconds: 50));
  expect(
    client.flowControlStateSizes['waiters'],
    greaterThan(0),
    reason: 'nothing parked, so this test proves nothing',
  );

  await thenDo();
  await parked.timeout(
    const Duration(seconds: 3),
    onTimeout: () => outcome = 'never completed',
  );
  return outcome;
}

void main() {
  test(
    'a send parked past the end of its stream is refused',
    () async {
      final (client, server) = RpcChannelTransport.pair(policy: _policy);
      final delivered = <int>[];
      final sub = server.incomingMessages.listen((m) {
        if (m.payload != null) delivered.add(m.payload!.length);
      });

      final streamId = client.createStream();
      // A per-stream view with NO consumer on the far side: messages are buffered
      // there and credit returns only as a consumer takes them, so none comes
      // back. Without this the peer credits on arrival and nothing ever parks.
      server.getMessagesForStream(streamId);
      await client.sendMetadata(
        streamId,
        RpcMetadata.forClientRequest('Svc', 'M'),
      );

      final outcome = await _parkOne(
        client,
        streamId,
        // `finishSending` now WAITS for the parked send, so it cannot be awaited
        // here — the credit never comes on this stream. Tearing the transport
        // down is what a call's deadline does, and it is what must wake the
        // sender with an answer.
        thenDo: () async {
          unawaited(client.finishSending(streamId));
          await Future<void>.delayed(const Duration(milliseconds: 100));
          await client.close();
        },
      );

      expect(
        outcome,
        isA<RpcStatusException>().having(
          (e) => e.statusCode,
          'statusCode',
          RpcStatus.unavailable,
        ),
        reason: 'the sender was told nothing: $outcome',
      );
      expect(
        delivered,
        hasLength(3),
        reason: 'only what was sent before the end may be delivered',
      );

      await sub.cancel();
      await server.close();
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );

  test(
    'a grant during the wait puts the message out before the end',
    () async {
      // The half that must NOT regress: a parked message whose credit arrives is
      // sent, and sent ahead of the end-of-stream that was held back for it.
      final (client, server) = RpcChannelTransport.pair(policy: _policy);
      final delivered = <int>[];
      var endSeenAfter = -1;
      final sub = server.incomingMessages.listen((m) {
        if (m.payload != null) delivered.add(m.payload!.length);
        if (m.isEndOfStream) endSeenAfter = delivered.length;
      });

      final streamId = client.createStream();
      final view = server.getMessagesForStream(streamId);
      await client.sendMetadata(
        streamId,
        RpcMetadata.forClientRequest('Svc', 'M'),
      );

      final outcome = await _parkOne(
        client,
        streamId,
        thenDo: () async {
          unawaited(client.finishSending(streamId));
          // A consumer arrives and drains, which is what returns credit.
          await view.take(3).toList();
          await Future<void>.delayed(const Duration(milliseconds: 200));
        },
      );

      expect(
        outcome,
        'written',
        reason: 'the grant arrived and it still failed',
      );
      expect(
        endSeenAfter,
        4,
        reason:
            'the end-of-stream must come after all four payloads, not after '
            '$endSeenAfter of them',
      );

      await sub.cancel();
      await client.close();
      await server.close();
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );
}
