// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// RpcChannelFrame.decode bounds a metadata frame by its declared length, as
// decodeAll does, before reading its payload.

import 'package:rpc_dart/transport.dart';
import 'package:test/test.dart';

void main() {
  final frame = RpcChannelFrame.encodeMetadata(
    streamId: 1,
    metadata: RpcMetadata([RpcHeader('x-big', 'v' * 200)]),
  );

  test('a metadata frame over the bound is refused', () {
    expect(
      () => RpcChannelFrame.decode(frame, maxMetadataLen: 64),
      throwsA(isA<RpcFrameException>()),
    );
  });

  test('one within the bound decodes', () {
    final decoded = RpcChannelFrame.decode(frame, maxMetadataLen: 1024);
    expect(decoded?.metadata?.getHeaderValue('x-big'), 'v' * 200);
  });
}
