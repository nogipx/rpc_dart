// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// Flag bits 2-7 of a channel frame are reserved: the receiver ignores them.
// That keeps them free for optional flags a later release adds without a new
// protocol version.

import 'package:rpc_dart/transport.dart';
import 'package:test/test.dart';

const _reserved = 0xFC;

Uint8List _withReservedBits(Uint8List frame) =>
    Uint8List.fromList(frame)..[4] |= _reserved;

void main() {
  test('a data frame decodes as if the reserved bits were 0', () {
    final frame = _withReservedBits(
      RpcChannelFrame.encodeData(
        streamId: 3,
        payload: Uint8List.fromList([1, 2, 3]),
      ),
    );

    final decoded = RpcChannelFrame.decode(frame)!;
    expect(decoded.streamId, 3);
    expect(decoded.isMetadata, isFalse);
    expect(decoded.endOfStream, isFalse);
    expect(decoded.payload, [1, 2, 3]);
  });

  test('a metadata frame keeps its kind and end-of-stream', () {
    final frame = _withReservedBits(
      RpcChannelFrame.encodeMetadata(
        streamId: 5,
        metadata: RpcMetadata([RpcHeader('x-a', 'b')]),
        endOfStream: true,
      ),
    );

    final (frames, consumed) = RpcChannelFrame.decodeAll(frame);
    expect(consumed, frame.length);
    expect(frames, hasLength(1));
    expect(frames.single.isMetadata, isTrue);
    expect(frames.single.endOfStream, isTrue);
    expect(frames.single.metadata?.getHeaderValue('x-a'), 'b');
  });

  test('an encoder writes the reserved bits as 0', () {
    final data = RpcChannelFrame.encodeData(
      streamId: 1,
      payload: Uint8List(1),
      endOfStream: true,
    );
    final metadata = RpcChannelFrame.encodeMetadata(
      streamId: 1,
      metadata: RpcMetadata([RpcHeader('x-a', 'b')]),
      endOfStream: true,
    );
    expect(data[4] & _reserved, 0);
    expect(metadata[4] & _reserved, 0);
  });
}
