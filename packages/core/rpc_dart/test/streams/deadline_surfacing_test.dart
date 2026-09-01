// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// RpcCallScope closes itself when the context deadline fires, and CallProcessor
// registered a disposer that closes its controllers. A bare close, though, is
// indistinguishable from the peer having finished:
//
//   * a server-stream call ended NORMALLY on deadline expiry -- the consumer
//     saw a clean onDone after a partial stream and could not tell a truncated
//     call from a complete one, so partial results looked like the whole set;
//   * a client-stream call reported UNAVAILABLE ("Stream closed without
//     receiving response") instead of the deadline it actually hit.
//
// CallProcessor now pushes RpcDeadlineExceededException onto the stream before
// the controllers close.

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

void main() {
  final codec = RpcCodec(RpcString.fromJson);

  test('a server stream that outlives its deadline errors, not completes', () {
    return _withTransports((client, server) async {
      // Answer with two items, then go silent -- never send a trailer.
      server.incomingMessages.listen((message) async {
        if (message.isMetadataOnly || message.payload == null) return;
        await server.sendMetadata(
          message.streamId,
          RpcMetadata.forServerInitialResponse(),
        );
        for (final value in ['one', 'two']) {
          await server.sendMessage(
            message.streamId,
            RpcMessageFrame.encode(codec.serialize(value.rpc)),
          );
        }
      });

      final caller = ServerStreamCaller<RpcString, RpcString>(
        transport: client,
        serviceName: 'S',
        methodName: 'M',
        requestCodec: codec,
        responseCodec: codec,
        context: RpcContext.withTimeout(const Duration(milliseconds: 200)),
      );

      final received = <String>[];
      await expectLater(
        caller.call('go'.rpc).map((r) => received.add(r.value)).drain<void>(),
        throwsA(isA<RpcDeadlineExceededException>()),
      );
      // What did arrive before the deadline is still delivered.
      expect(received, ['one', 'two']);
    });
  });

  test('a client stream that outlives its deadline says so', () {
    return _withTransports((client, server) async {
      // No responder at all: the response never arrives.
      final caller = ClientStreamCaller<RpcString, RpcString>(
        transport: client,
        serviceName: 'S',
        methodName: 'M',
        requestCodec: codec,
        responseCodec: codec,
        context: RpcContext.withTimeout(const Duration(milliseconds: 200)),
      );

      await caller.send('a'.rpc);
      await expectLater(
        caller.finishSending(),
        throwsA(isA<RpcDeadlineExceededException>()),
      );
    });
  });

  test('a call that completes before its deadline is unaffected', () {
    return _withTransports((client, server) async {
      server.incomingMessages.listen((message) async {
        if (message.isMetadataOnly || message.payload == null) return;
        await server.sendMetadata(
          message.streamId,
          RpcMetadata.forServerInitialResponse(),
        );
        await server.sendMessage(
          message.streamId,
          RpcMessageFrame.encode(codec.serialize('done'.rpc)),
        );
        await server.sendMetadata(
          message.streamId,
          RpcMetadata.forTrailer(RpcStatus.ok),
          endStream: true,
        );
      });

      final caller = ClientStreamCaller<RpcString, RpcString>(
        transport: client,
        serviceName: 'S',
        methodName: 'M',
        requestCodec: codec,
        responseCodec: codec,
        context: RpcContext.withTimeout(const Duration(seconds: 30)),
      );

      await caller.send('a'.rpc);
      expect((await caller.finishSending()).value, 'done');
    });
  });
}

Future<void> _withTransports(
  Future<void> Function(RpcChannelTransport client, RpcChannelTransport server)
  body,
) async {
  final (client, server) = RpcChannelTransport.pair();
  try {
    await body(client, server);
  } finally {
    await client.close();
    await server.close();
  }
}
