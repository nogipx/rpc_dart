// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// The zero-copy channel passes `payload` BY REFERENCE and delivers it a microtask
// later, so a sender that reuses its buffer after `await sendMessage` rewrites what
// the receiver reads. Only `directPayload` carried a warning about this.
//
//     the sender scribbles 0xFF after the await   the receiver read 0xFF x4
//     the sender leaves it alone                  the receiver read 0xAA x4
//
// This file PINS that rule rather than removing it. The bytes are handed over, the
// mirror of what `IRpcChannel.incoming` already states for a delivered chunk, and it
// is what being zero-copy costs -- B-116's owner decision settled the same trade in
// the other direction. A copy on send would make the first row read 0xAA and would
// be a speed trade on the only transport whose point is not copying, so it is the
// owner's call and not a quiet improvement.
//
// If a future change adds that copy, the WITNESS below fails and says so. It is the
// contract's only witness: a doc comment has none.
@TestOn('vm')
library;

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

/// Sends one frame of 0xAA, optionally scribbling 0xFF over the buffer right after
/// the await, and returns the body the receiver read.
Future<List<int>> _bodyAfterSend({required bool mutateAfterSend}) async {
  final (client, server) = RpcChannelTransport.memoryPair();
  final received = <int>[];
  final sub = server.incomingMessages.listen((m) {
    final p = m.payload;
    if (p != null) received.addAll(p);
  });
  addTearDown(() async {
    await sub.cancel();
    await client.close().catchError((Object _) {});
    await server.close().catchError((Object _) {});
  });

  final id = client.createStream();
  await client.sendMetadata(id, RpcMetadata.forClientRequest('Svc', 'M'));

  // Built by hand so the 5-byte gRPC prefix and the body are both known: not
  // compressed, length 4, then 0xAA.
  final buffer = Uint8List.fromList([0, 0, 0, 0, 4, 0xAA, 0xAA, 0xAA, 0xAA]);
  await client.sendMessage(id, buffer);
  if (mutateAfterSend) {
    for (var i = 5; i < buffer.length; i++) {
      buffer[i] = 0xFF;
    }
  }
  await Future<void>.delayed(const Duration(milliseconds: 200));

  return received.length > 5 ? received.sublist(5) : received;
}

void main() {
  // WITNESS of the CONTRACT, not of a bug: the bytes are handed over, so a sender
  // that keeps writing to them is writing into the receiver's frame.
  test('a sent payload belongs to the receiver, not the sender', () async {
    expect(
      await _bodyAfterSend(mutateAfterSend: true),
      [0xFF, 0xFF, 0xFF, 0xFF],
      reason:
          'the zero-copy channel delivers the same list the sender passed; if '
          'this now reads 0xAA someone added a copy on send, which is a speed '
          'trade on the one transport whose point is not copying -- see the '
          'ownership rule on RpcTransportMessage.payload',
    );
  });

  // CONTROL. A sender that respects the rule gets its bytes through intact, so the
  // row above is about the REUSE and not about the channel mangling payloads.
  test(
    'CONTROL: a sender that leaves its buffer alone is delivered intact',
    () async {
      expect(await _bodyAfterSend(mutateAfterSend: false), [
        0xAA,
        0xAA,
        0xAA,
        0xAA,
      ]);
    },
  );
}
