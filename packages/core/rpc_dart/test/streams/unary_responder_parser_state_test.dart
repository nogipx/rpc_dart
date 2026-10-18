// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// One endpoint serves many unary streams on a transport. A message parser
// keeps a reassembly buffer between invocations, so a stream that ends with a
// partial gRPC frame in the buffer — a truncated or hostile request — must
// not leave those bytes behind for the next stream. If it did, the next
// stream's well-formed request would be parsed on top of them and fail
// INTERNAL.

import 'dart:async';

import 'package:rpc_dart/src/_internal.dart';
import 'package:test/test.dart';

/// Service `S`, unary `M`: echoes its request.
final class _Echo extends RpcResponderContract {
  _Echo(this._codec) : super('S');

  final IRpcCodec<RpcString> _codec;

  @override
  void setup() {
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'M',
      handler: (request, {RpcContext? context}) async => request,
      requestCodec: _codec,
      responseCodec: _codec,
    );
  }
}

void main() {
  final codec = RpcCodec(RpcString.fromJson);

  test('a truncated stream does not poison another stream', () async {
    final (client, server) = RpcChannelTransport.pair();

    final responder = RpcResponderEndpoint(transport: server);
    responder.registerServiceContract(_Echo(codec));
    responder.start();

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

    // A fails on its own merits. It is answered INTERNAL because the request
    // was cut: the peer half-closed with a frame header promising bytes it
    // never sent. The responder waits for the rest of an incomplete frame, so
    // a half-close is what decides there will be no rest.
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

    // A parser shared with A would hand B A's leftovers and answer INTERNAL.
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
