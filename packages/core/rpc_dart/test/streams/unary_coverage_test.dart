// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';
import '../utils/transport_wrappers.dart';

void main() {
  group('Unary streams: serialized paths & responder branches', () {
    final codec = RpcCodec(RpcString.fromJson);

    test('UnaryCaller/UnaryResponder use serialized framing when zero-copy off',
        () async {
      final (rawClient, rawServer) = RpcInMemoryTransport.pair();
      final clientTransport = NoZeroCopyTransport(rawClient);
      final serverTransport = NoZeroCopyTransport(rawServer);

      final server = UnaryResponder<RpcString, RpcString>(
        transport: serverTransport,
        serviceName: 'S',
        methodName: 'M',
        requestCodec: codec,
        responseCodec: codec,
        handler: (req) => 'Echo: $req'.rpc,
      );

      final client = UnaryCaller<RpcString, RpcString>(
        transport: clientTransport,
        serviceName: 'S',
        methodName: 'M',
        requestCodec: codec,
        responseCodec: codec,
      );

      final response = await client.call('ping'.rpc);
      expect(response, 'Echo: ping'.rpc);

      await client.close();
      await server.close();
      await rawClient.close();
      await rawServer.close();
    });

    test('UnaryResponder serialized path sends error trailer on handler throw',
        () async {
      final (rawClient, rawServer) = RpcInMemoryTransport.pair();
      final clientTransport = NoZeroCopyTransport(rawClient);
      final serverTransport = NoZeroCopyTransport(rawServer);

      final server = UnaryResponder<RpcString, RpcString>(
        transport: serverTransport,
        serviceName: 'S',
        methodName: 'M',
        requestCodec: codec,
        responseCodec: codec,
        handler: (_) => throw StateError('boom'),
      );

      final client = UnaryCaller<RpcString, RpcString>(
        transport: clientTransport,
        serviceName: 'S',
        methodName: 'M',
        requestCodec: codec,
        responseCodec: codec,
      );

      await expectLater(
        () => client.call('ping'.rpc),
        throwsA(isA<Exception>().having(
          (e) => e.toString(),
          'msg',
          contains('gRPC error'),
        )),
      );

      await client.close();
      await server.close();
      await rawClient.close();
      await rawServer.close();
    });

    test(
        'UnaryResponder.handleDirectMessage falls back to serialization when zero-copy off',
        () async {
      final (rawClient, rawServer) = RpcInMemoryTransport.pair();
      final serverTransport = NoZeroCopyTransport(rawServer);

      final server = UnaryResponder<RpcString, RpcString>(
        id: 1,
        transport: serverTransport,
        serviceName: 'S',
        methodName: 'M',
        requestCodec: codec,
        responseCodec: codec,
        handler: (req) => 'ok:$req'.rpc,
      );

      final received = <RpcTransportMessage>[];
      final sub = rawClient.incomingMessages
          .where((m) => m.streamId == 1)
          .listen(received.add);

      await server.handleDirectMessage(
        RpcTransportMessage.withDirectObject(
          directPayload: 'req'.rpc,
          streamId: 1,
          isEndOfStream: true,
        ),
      );

      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(received.where((m) => m.isMetadataOnly).length,
          greaterThanOrEqualTo(2));

      final payloadMsg =
          received.firstWhere((m) => !m.isMetadataOnly && m.payload != null);
      final parser = RpcMessageParser();
      final frames = parser(payloadMsg.payload!);
      expect(frames, isNotEmpty);
      expect(codec.deserialize(frames.first), 'ok:req'.rpc);

      await sub.cancel();
      await server.close();
      await rawClient.close();
      await rawServer.close();
    });

    test('UnaryResponder ignores messages for other stream id', () async {
      final (rawClient, rawServer) = RpcInMemoryTransport.pair();
      final clientTransport = NoZeroCopyTransport(rawClient);
      final serverTransport = NoZeroCopyTransport(rawServer);

      final server = UnaryResponder<RpcString, RpcString>(
        id: 1,
        transport: serverTransport,
        serviceName: 'S',
        methodName: 'M',
        requestCodec: codec,
        responseCodec: codec,
        handler: (req) => 'ok:$req'.rpc,
      );

      final received = <RpcTransportMessage>[];
      final sub = rawClient.incomingMessages.listen(received.add);

      // Send a framed request on stream 3 (not owned by this responder).
      await clientTransport.sendMetadata(
        3,
        RpcMetadata.forClientRequest('S', 'M'),
      );
      await clientTransport.sendMessage(
        3,
        RpcMessageFrame.encode(codec.serialize('req'.rpc)),
        endStream: true,
      );

      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(received.where((m) => m.streamId == 3), isEmpty);

      await sub.cancel();
      await server.close();
      await rawClient.close();
      await rawServer.close();
    });

    test('UnaryResponder.handleMessage early-exit branches', () async {
      final (rawClient, rawServer) = RpcInMemoryTransport.pair();
      final serverTransport = NoZeroCopyTransport(rawServer);

      final cancelled = RpcCancellationToken.cancelled('stop');
      final server = UnaryResponder<RpcString, RpcString>(
        id: 1,
        transport: serverTransport,
        serviceName: 'S',
        methodName: 'M',
        requestCodec: codec,
        responseCodec: codec,
        context: RpcContext.withCancellation(cancelled),
        handler: (req) => 'ok:$req'.rpc,
      );

      final received = <RpcTransportMessage>[];
      final sub = rawClient.incomingMessages.listen(received.add);

      // 1) Cancelled context => request is ignored.
      await server.handleMessage(
        RpcTransportMessage.withPayload(
          payload: RpcMessageFrame.encode(codec.serialize('req'.rpc)),
          streamId: 1,
          isEndOfStream: true,
        ),
      );

      // 2) Wrong stream id for this responder => ignored.
      await server.handleMessage(
        RpcTransportMessage.withPayload(
          payload: RpcMessageFrame.encode(codec.serialize('req'.rpc)),
          streamId: 3,
          isEndOfStream: true,
        ),
      );

      // 3) Metadata-only message => ignored.
      await server.handleMessage(
        RpcTransportMessage.withMetadata(
          metadata: RpcMetadata.forClientRequest('S', 'M'),
          streamId: 1,
          isEndOfStream: false,
          methodPath: '/S/M',
        ),
      );

      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(received, isEmpty);

      await sub.cancel();
      await server.close();
      await rawClient.close();
      await rawServer.close();
    });
  });
}
