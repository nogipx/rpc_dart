// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// Each unary call parses its response with its own parser. A call that ends
// while the parser holds a partial gRPC frame -- a peer that truncated its
// response, a call abandoned at its deadline mid-frame -- leaves nothing for
// the next call on the same transport to read before its own response.

import 'package:rpc_dart/src/_internal.dart';
import 'package:test/test.dart';

void main() {
  final codec = RpcCodec(RpcString.fromJson);

  test('a truncated response does not poison the next call', () async {
    final (client, server) = RpcChannelTransport.pair();

    // The server answers the first request with a gRPC frame whose header
    // declares 100 payload bytes but which carries only 4, then answers the
    // second request normally.
    var served = 0;
    final sub = server.incomingMessages.listen((message) async {
      if (message.isMetadataOnly || message.payload == null) return;
      final streamId = message.streamId;
      served++;

      if (served == 1) {
        await server.sendMessage(
          streamId,
          Uint8List.fromList([0, 0, 0, 0, 100, 1, 2, 3, 4]),
        );
        return;
      }

      await server.sendMetadata(
        streamId,
        RpcMetadata.forServerInitialResponse(),
      );
      await server.sendMessage(
        streamId,
        RpcMessageFrame.encode(codec.serialize('ok'.rpc)),
      );
      await server.sendMetadata(
        streamId,
        RpcTrailers.status(RpcStatus.ok),
        endStream: true,
      );
    });

    UnaryCaller<RpcString, RpcString> caller({RpcContext? context}) =>
        UnaryCaller<RpcString, RpcString>(
          transport: client,
          serviceName: 'S',
          methodName: 'M',
          requestCodec: codec,
          responseCodec: codec,
          context: context,
        );

    // First call never completes: the frame is incomplete, so the parser
    // buffers it and emits nothing until the deadline.
    await expectLater(
      caller(
        context: RpcContext.withTimeout(const Duration(milliseconds: 100)),
      ).call('first'.rpc),
      throwsA(isA<RpcDeadlineExceededException>()),
    );

    // Second call must be unaffected. With a shared parser the 9 orphaned
    // bytes preceded this response and it never completed either.
    final response = await caller()
        .call('second'.rpc)
        .timeout(const Duration(seconds: 5));
    expect(response.value, 'ok');
    expect(served, 2);

    await sub.cancel();
    await client.close();
    await server.close();
  });
}
