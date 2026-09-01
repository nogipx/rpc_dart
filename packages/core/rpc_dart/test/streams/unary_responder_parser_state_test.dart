// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// UnaryResponder keys every piece of per-call state by stream id
// (_streamStates) and with the default `id == 0` it answers on any stream, so
// one instance can serve several calls. Its RpcMessageParser was the one
// exception: a single instance shared by every stream. Because the parser
// keeps a reassembly buffer between invocations, a stream that ended with a
// partial gRPC frame in the buffer — a truncated or hostile request — left
// those bytes behind, and the next stream's request was parsed on top of them.
// The victim call then failed with INTERNAL ("Failed to extract message from
// payload") even though its own bytes were perfectly well-formed.

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

void main() {
  final codec = RpcCodec(RpcString.fromJson);

  test('a truncated stream does not poison another stream', () async {
    final (client, server) = RpcChannelTransport.pair();

    final responder = UnaryResponder<RpcString, RpcString>(
      transport: server,
      serviceName: 'S',
      methodName: 'M',
      requestCodec: codec,
      responseCodec: codec,
      handler: (request) async => request,
    );

    final requestMetadata = RpcMetadata.forClientRequest('S', 'M');

    // Stream A: a gRPC frame whose header promises 100 payload bytes but
    // carries only 4, so the parser buffers them and yields nothing.
    final streamA = client.createStream();
    final statusA = Completer<String>();
    final subA = client.getMessagesForStream(streamA).listen((message) {
      final status = message.metadata?.getHeaderValue(RpcHeaders.grpcStatus);
      if (status != null && !statusA.isCompleted) statusA.complete(status);
    });

    await client.sendMetadata(streamA, requestMetadata);
    await client.sendMessage(
      streamA,
      Uint8List.fromList([0, 0, 0, 0, 100, 1, 2, 3, 4]),
      endStream: true,
    );

    // A fails on its own merits — that part is expected and not the bug.
    expect(
      await statusA.future.timeout(const Duration(seconds: 5)),
      RpcStatus.internal.toString(),
    );

    // Stream B: a well-formed request sent only after A is fully resolved, so
    // the 4 orphaned bytes are definitely sitting in the buffer by now.
    final streamB = client.createStream();
    final statusB = Completer<String>();
    final payloadB = Completer<Uint8List>();
    // The responder compresses its response whenever the request advertised an
    // encoding it supports, so read back what it actually chose.
    var responseEncoding = RpcGrpcCompression.identity;
    final subB = client.getMessagesForStream(streamB).listen((message) {
      if (!message.isMetadataOnly &&
          message.payload != null &&
          !payloadB.isCompleted) {
        payloadB.complete(message.payload!);
      }
      final encoding = message.metadata?.getHeaderValue(
        RpcHeaders.grpcEncoding,
      );
      if (encoding != null) responseEncoding = encoding;
      final status = message.metadata?.getHeaderValue(RpcHeaders.grpcStatus);
      if (status != null && !statusB.isCompleted) statusB.complete(status);
    });

    await client.sendMetadata(streamB, requestMetadata);
    await client.sendMessage(
      streamB,
      RpcMessageFrame.encode(codec.serialize('hello'.rpc)),
      endStream: true,
    );

    // With a shared parser B inherited A's leftovers and answered INTERNAL.
    expect(
      await statusB.future.timeout(const Duration(seconds: 5)),
      RpcStatus.ok.toString(),
    );

    final parser = RpcMessageParser(
      decompressor: (payload, {int? maxOutputBytes}) =>
          RpcGrpcCompression.decompress(
            payload,
            encoding: responseEncoding,
            maxOutputBytes: maxOutputBytes,
          ),
    );
    final frames = parser(
      await payloadB.future.timeout(const Duration(seconds: 5)),
    );
    expect(codec.deserialize(frames.single).value, 'hello');

    await subA.cancel();
    await subB.cancel();
    await responder.close();
    await client.close();
    await server.close();
  });
}
