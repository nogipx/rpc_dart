// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// `close()` cancelled the inbound subscription straight away, which dropped whatever
// the peer had already queued toward this side while this side's own queued frames
// still went out. With both ends queuing a frame in the same turn and the client
// closing:
//
//     the client received  []            <- the peer's frame, gone
//     the server received  [from-client]
//
// mirrored when the server closes, so it is about the CLOSING side rather than the
// role.
//
// PINNED rather than fixed, and the reason is measured. One event-loop turn before
// the cancel does deliver that frame -- the shape `RpcHttpServer.stop` needed for its
// 503 -- but the turn lands inside the close CASCADE whichever side of `_output.close`
// it goes: the peer's `onDone`, its channel's close and its transport's all shift a
// turn later. `in_memory_transport_test`'s "a send with nowhere to go is refused, not
// reported sent" then FAILS, because the peer's `sendMessage` right after
// `await close()` stops throwing and succeeds silently. Of the two losses that is the
// worse one.
//
// The second rule here is PINNED rather than changed: `send` on a closed channel
// returns normally and delivers nothing. Both shipped implementations do
// `if (_closed) return`, so 2 of 2 agree it is the convention; callers that need an
// error go through `RpcChannelTransport`, which throws `RpcClosedException`. It is
// now on the interface, and this is its witness:
//
//     the send           returned normally
//     the peer received  []
//     our isClosed       true
@TestOn('vm')
library;

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

RpcTransportMessage _frame(int streamId, String tag) => RpcTransportMessage(
  streamId: streamId,
  metadata: RpcMetadata([RpcHeader('x-tag', tag)]),
);

/// Both ends queue a frame in the same turn, then one closes. Returns what each
/// side received.
Future<(List<String>, List<String>)> _queueBothThenClose({
  required bool clientCloses,
}) async {
  final (clientCh, serverCh) = RpcDirectMultiplexedChannel.pair();
  final atClient = <String>[];
  final atServer = <String>[];
  clientCh.incoming.listen(
    (m) => atClient.add(m.metadata?.getHeaderValue('x-tag') ?? '?'),
    onError: (Object _) {},
  );
  serverCh.incoming.listen(
    (m) => atServer.add(m.metadata?.getHeaderValue('x-tag') ?? '?'),
    onError: (Object _) {},
  );
  await Future<void>.delayed(const Duration(milliseconds: 50));

  // Nothing awaited between these three, so both frames are queued before the
  // close runs -- which is the race the convention is about.
  unawaited(clientCh.send(_frame(1, 'from-client')));
  unawaited(serverCh.send(_frame(2, 'from-server')));
  unawaited((clientCloses ? clientCh : serverCh).close());
  await Future<void>.delayed(const Duration(milliseconds: 200));

  return (atClient, atServer);
}

void main() {
  test('close drops what the peer queued and delivers what we queued', () async {
    final (atClient, atServer) = await _queueBothThenClose(clientCloses: true);

    expect(atServer, [
      'from-client',
    ], reason: 'the closing side still gets its own queued frame out');
    expect(
      atClient,
      isEmpty,
      reason:
          'the peer\'s queued frame is dropped, and the alternative costs a turn '
          'inside the close cascade -- which makes a send after `await close()` '
          'succeed silently instead of being refused',
    );
  });

  // The same with the roles swapped: the rule is about the CLOSING side and not
  // about which end is the client.
  test('mirrored when the server closes instead', () async {
    final (atClient, atServer) = await _queueBothThenClose(clientCloses: false);

    expect(atClient, ['from-server']);
    expect(atServer, isEmpty);
  });

  test(
    'a send on a closed channel returns normally and delivers nothing',
    () async {
      final (clientCh, serverCh) = RpcDirectMultiplexedChannel.pair();
      final atServer = <String>[];
      serverCh.incoming.listen(
        (m) => atServer.add(m.metadata?.getHeaderValue('x-tag') ?? '?'),
        onError: (Object _) {},
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));

      await serverCh.close();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      // The peer's close propagated, so this side knows it is closed too.
      expect(clientCh.isClosed, isTrue);

      await expectLater(clientCh.send(_frame(1, 'after-close')), completes);
      await Future<void>.delayed(const Duration(milliseconds: 150));

      expect(
        atServer,
        isEmpty,
        reason:
            'the future completing is not evidence the peer received anything; '
            'callers that need an error go through RpcChannelTransport, which '
            'throws RpcClosedException',
      );
    },
  );
}
