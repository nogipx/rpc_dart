// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// The pre-method budget charged the PAYLOAD only, so metadata was free.
//
// `bufferPreMethod` parks a frame whose method is not yet resolved, against a
// per-connection ceiling of maxMessageLengthBytes. It charged
// `message.payload?.length ?? 0`, so a frame carrying one payload byte and a
// large header block cost the budget ONE BYTE while retaining the whole block.
//
// Worse than the queue's bound that round 279 fixed: the queue has a 4096-EVENT
// ceiling behind its byte bound, and `_preMethodBufferedMessages` is a plain
// List with no count cap. If the bytes read as ~0, nothing else is counting.
//
// Measured, 4000 frames of 2000 tiny headers each, the pipeline's admission
// check transcribed:
//
//   arm       charge  parked  refused   charged      RSS
//   metadata  old       4000        0  0.00 MiB   789.2 MiB
//   metadata  fixed      106     3894  15.93 MiB   27.6 MiB
//   payload   fixed     4000        0  15.63 MiB   11.7 MiB
//
// The budget did not bind at all. RSS is not what this test asserts on -- the
// deterministic observable is what the accounting reports.

@TestOn('vm')
library;

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

/// One payload byte, so the frame takes the pre-method path, plus a header
/// block that costs four orders of magnitude more.
RpcTransportMessage _metadataHeavy({int headers = 2000}) => RpcTransportMessage(
  streamId: 1,
  payload: Uint8List(1),
  metadata: RpcMetadata([
    for (var h = 0; h < headers; h++) RpcHeader('h$h', 'v$h'),
  ]),
);

void main() {
  test('a parked frame is charged for its metadata, not just its payload', () {
    // WITNESS. Pre-fix this was 1 -- the payload byte -- for a frame holding
    // 2000 headers.
    final state = RpcResponderStreamState(1);
    state.bufferPreMethod(_metadataHeavy());

    expect(
      state.preMethodBufferedBytes,
      greaterThan(2000 * 32),
      reason: 'the header block a parked frame retains must be charged',
    );
  });

  test('the ceiling therefore stops a metadata flood', () {
    // WITNESS. Pre-fix all 200 were parked, because each charged one byte.
    const ceiling = 16 * 1024 * 1024;
    final state = RpcResponderStreamState(1);

    var charged = 0;
    var parked = 0;
    for (var i = 0; i < 200; i++) {
      final message = _metadataHeavy();
      final bytes = message.bufferedBytes;
      if (charged + bytes > ceiling) continue;
      charged += bytes;
      state.bufferPreMethod(message);
      parked++;
    }

    expect(
      parked,
      lessThan(200),
      reason: 'the connection-wide ceiling must refuse some of them',
    );
  });

  test('GUARD: a payload-only frame is charged exactly its payload', () {
    // The charge must not re-price the case the budget was written for.
    final state = RpcResponderStreamState(1);
    state.bufferPreMethod(
      RpcTransportMessage(streamId: 1, payload: Uint8List(4096)),
    );

    expect(state.preMethodBufferedBytes, 4096);
  });

  test('GUARD: taking the buffer clears the charge', () {
    // The release path reads this number; if it desyncs, the connection-wide
    // total never returns to zero and legitimate calls start being refused.
    final state = RpcResponderStreamState(1);
    state.bufferPreMethod(_metadataHeavy(headers: 10));
    expect(state.preMethodBufferedBytes, greaterThan(0));

    state.takePreMethodBufferedMessages();
    expect(state.preMethodBufferedBytes, 0);
  });
}
