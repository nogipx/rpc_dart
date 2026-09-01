// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// UnaryCaller is reusable: call() takes no identity of its own, the class
// exposes close(), and nothing documents a one-shot lifetime. But it used to
// hold ONE RpcMessageParser (and one _peerGrpcEncoding) for the whole
// instance, and RpcMessageParser carries a reassembly buffer across
// invocations. A call that ended while the parser still held a partial gRPC
// frame — a peer that truncated its response, or a call abandoned on timeout
// mid-frame — left those bytes in the buffer, and the NEXT call's response was
// appended to them. The parser then read the stale 5-byte header and either
// waited forever for a message that would never arrive or handed the codec a
// window of the wrong bytes.

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
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
        RpcMetadata.forTrailer(RpcStatus.ok),
        endStream: true,
      );
    });

    final caller = UnaryCaller<RpcString, RpcString>(
      transport: client,
      serviceName: 'S',
      methodName: 'M',
      requestCodec: codec,
      responseCodec: codec,
    );

    // First call never completes: the frame is incomplete, so the parser
    // buffers it and emits nothing.
    await expectLater(
      caller.call('first'.rpc, timeout: const Duration(milliseconds: 100)),
      throwsA(isA<TimeoutException>()),
    );

    // Second call must be unaffected. With a shared parser the 9 orphaned
    // bytes preceded this response and it timed out too.
    final response = await caller.call(
      'second'.rpc,
      timeout: const Duration(seconds: 5),
    );
    expect(response.value, 'ok');
    expect(served, 2);

    await sub.cancel();
    await caller.close();
    await client.close();
    await server.close();
  });
}
