import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

import '../utils/transport_wrappers.dart';

void main() {
  group('Bidirectional streams: extra coverage', () {
    final codec = RpcCodec(RpcString.fromJson);

    test('requestSink forwards requests and finishes on close', () async {
      final (rawClient, rawServer) = RpcInMemoryTransport.pair();
      final clientTransport = NoZeroCopyTransport(rawClient);
      final serverTransport = NoZeroCopyTransport(rawServer);

      final server = BidirectionalStreamResponder<RpcString, RpcString>(
        id: 1,
        transport: serverTransport,
        serviceName: 'S',
        methodName: 'M',
        requestCodec: codec,
        responseCodec: codec,
      );
      server.bindToMessageStream(
        serverTransport.incomingMessages.where((m) => m.streamId == 1),
      );

      final received = <RpcString>[];
      final done = Completer<void>();
      server.requests.listen(
        received.add,
        onDone: done.complete,
      );

      final client = BidirectionalStreamCaller<RpcString, RpcString>(
        transport: clientTransport,
        serviceName: 'S',
        methodName: 'M',
        requestCodec: codec,
        responseCodec: codec,
      );

      client.requestSink.add('a'.rpc);
      client.requestSink.add('b'.rpc);
      await client.requestSink.close();

      await done.future.timeout(const Duration(seconds: 2));
      expect(received, ['a'.rpc, 'b'.rpc]);

      await client.close();
      await server.close();
      await rawClient.close();
      await rawServer.close();
    });

    test('responseSink forwards responses and finishReceiving completes done',
        () async {
      final (rawClient, rawServer) = RpcInMemoryTransport.pair();
      final clientTransport = NoZeroCopyTransport(rawClient);
      final serverTransport = NoZeroCopyTransport(rawServer);

      final server = BidirectionalStreamResponder<RpcString, RpcString>(
        id: 1,
        transport: serverTransport,
        serviceName: 'S',
        methodName: 'M',
        requestCodec: codec,
        responseCodec: codec,
      );
      server.bindToMessageStream(
        serverTransport.incomingMessages.where((m) => m.streamId == 1),
      );

      final client = BidirectionalStreamCaller<RpcString, RpcString>(
        transport: clientTransport,
        serviceName: 'S',
        methodName: 'M',
        requestCodec: codec,
        responseCodec: codec,
      );

      final payloads = <RpcString>[];
      final sub = client.responses.listen((msg) {
        if (!msg.isMetadataOnly && msg.payload != null) {
          payloads.add(msg.payload!);
        }
      });

      // Start the stream.
      await client.send('start'.rpc);

      server.responseSink.add('x'.rpc);
      server.responseSink.add('y'.rpc);
      await server.responseSink.close();

      await server.done.timeout(const Duration(seconds: 2));
      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(payloads, ['x'.rpc, 'y'.rpc]);

      await sub.cancel();
      await client.close();
      await server.close();
      await rawClient.close();
      await rawServer.close();
    });

    test('payloadResponses throws on non-OK gRPC trailer', () async {
      final (rawClient, rawServer) = RpcInMemoryTransport.pair();
      final clientTransport = NoZeroCopyTransport(rawClient);
      final serverTransport = NoZeroCopyTransport(rawServer);

      final server = BidirectionalStreamResponder<RpcString, RpcString>(
        id: 1,
        transport: serverTransport,
        serviceName: 'S',
        methodName: 'M',
        requestCodec: codec,
        responseCodec: codec,
      );
      server.bindToMessageStream(
        serverTransport.incomingMessages.where((m) => m.streamId == 1),
      );

      final client = BidirectionalStreamCaller<RpcString, RpcString>(
        transport: clientTransport,
        serviceName: 'S',
        methodName: 'M',
        requestCodec: codec,
        responseCodec: codec,
      );

      // Start the stream so server has a stream id.
      await client.send('start'.rpc);
      await server.sendError(RpcStatus.internal, 'boom');

      await expectLater(
        () => client.payloadResponses.toList(),
        throwsA(
          isA<Exception>().having(
            (e) => e.toString(),
            'msg',
            contains('gRPC error'),
          ),
        ),
      );

      await client.close();
      await server.close();
      await rawClient.close();
      await rawServer.close();
    });
  });
}
