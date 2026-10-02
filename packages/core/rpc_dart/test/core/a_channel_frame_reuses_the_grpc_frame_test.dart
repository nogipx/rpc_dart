// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// A channel transport frames a gRPC frame a second time. A large gRPC frame is
// built with room in front, so the channel header is written there and the
// message is not copied again. Once only: a frame sent twice must not have its
// first header overwritten.

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

void main() {
  test('a large gRPC frame is not copied into its channel frame', () {
    final grpc = RpcMessageFrame.encode(Uint8List(64 * 1024));
    final frame = RpcChannelFrame.encodeData(streamId: 3, payload: grpc);
    expect(frame.length, RpcChannelFrame.headerSize + grpc.length);
    // Shared memory: a write into the gRPC frame shows in the channel frame.
    grpc[100] = 7;
    expect(frame[RpcChannelFrame.headerSize + 100], 7);
    final decoded = RpcChannelFrame.decode(frame)!;
    expect(decoded.streamId, 3);
    expect(decoded.payload!.length, grpc.length);
  });

  test('GUARD: the same gRPC frame sent twice keeps the first header', () {
    final grpc = RpcMessageFrame.encode(Uint8List(64 * 1024));
    final first = RpcChannelFrame.encodeData(streamId: 3, payload: grpc);
    final second = RpcChannelFrame.encodeData(
      streamId: 5,
      payload: grpc,
      endOfStream: true,
    );
    expect(RpcChannelFrame.decode(first)!.streamId, 3);
    expect(RpcChannelFrame.decode(first)!.endOfStream, isFalse);
    expect(RpcChannelFrame.decode(second)!.streamId, 5);
  });

  test('GUARD: a caller-made list is copied, never written in front of', () {
    final backing = Uint8List(RpcChannelFrame.headerSize + 64 * 1024)
      ..fillRange(0, RpcChannelFrame.headerSize, 0xAA);
    final payload = Uint8List.sublistView(backing, RpcChannelFrame.headerSize);
    RpcChannelFrame.encodeData(streamId: 3, payload: payload);
    expect(backing.take(RpcChannelFrame.headerSize), everyElement(0xAA));
  });

  test('GUARD: a small gRPC frame round-trips unchanged', () {
    final grpc = RpcMessageFrame.encode(Uint8List.fromList([1, 2, 3]));
    final frame = RpcChannelFrame.encodeData(streamId: 1, payload: grpc);
    expect(RpcChannelFrame.decode(frame)!.payload, grpc);
  });
}
