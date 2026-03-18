// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

import '../utils/transport_wrappers.dart';

void main() {
  group('Streams: validation & edge cases', () {
    final codec = RpcCodec(RpcString.fromJson);

    test('UnaryCaller throws when context cancelled before call', () async {
      final (clientTransport, serverTransport) = RpcInMemoryTransport.pair();
      final token = RpcCancellationToken();
      token.cancel('stop');
      final context = RpcContext.withCancellation(token);

      final client = UnaryCaller<RpcString, RpcString>(
        transport: clientTransport,
        serviceName: 'S',
        methodName: 'M',
        requestCodec: codec,
        responseCodec: codec,
        context: context,
      );

      await expectLater(
        () => client.call('x'.rpc),
        throwsA(isA<RpcCancelledException>()),
      );

      await clientTransport.close();
      await serverTransport.close();
    });

    test('UnaryCaller throws when context deadline already expired', () async {
      final (clientTransport, serverTransport) = RpcInMemoryTransport.pair();
      final context =
          RpcContext.withDeadline(DateTime.fromMillisecondsSinceEpoch(0));

      final client = UnaryCaller<RpcString, RpcString>(
        transport: clientTransport,
        serviceName: 'S',
        methodName: 'M',
        requestCodec: codec,
        responseCodec: codec,
        context: context,
      );

      await expectLater(
        () => client.call('x'.rpc),
        throwsA(isA<RpcDeadlineExceededException>()),
      );

      await clientTransport.close();
      await serverTransport.close();
    });

    test('ServerStreamCaller validates codec combinations', () async {
      final (clientTransport, serverTransport) = RpcInMemoryTransport.pair();

      expect(
        () => ServerStreamCaller<RpcString, RpcString>(
          transport: clientTransport,
          serviceName: 'S',
          methodName: 'M',
          requestCodec: codec,
          responseCodec: null,
        ),
        throwsArgumentError,
      );

      expect(
        () => ServerStreamCaller<RpcString, RpcString>(
          transport: clientTransport,
          serviceName: 'S',
          methodName: 'M',
          requestCodec: null,
          responseCodec: codec,
        ),
        throwsArgumentError,
      );

      await clientTransport.close();
      await serverTransport.close();
    });

    test('ServerStreamCaller validates zero-copy requirements', () async {
      final (clientTransport, serverTransport) = RpcInMemoryTransport.pair();
      final transport = NoZeroCopyTransport(clientTransport);
      expect(
        () => ServerStreamCaller<RpcString, RpcString>(
          transport: transport,
          serviceName: 'S',
          methodName: 'M',
          // null codecs => request zero-copy
        ),
        throwsArgumentError,
      );

      await clientTransport.close();
      await serverTransport.close();
    });

    test('ServerStreamCaller.send can only be called once', () async {
      final (clientTransport, serverTransport) = RpcInMemoryTransport.pair();

      final server = ServerStreamResponder<RpcString, RpcString>(
        id: 1,
        transport: serverTransport,
        serviceName: 'S',
        methodName: 'M',
        requestCodec: codec,
        responseCodec: codec,
        handler: (request) async* {
          yield 'ok'.rpc;
        },
      );
      server.bindToMessageStream(
        serverTransport.incomingMessages.where((m) => m.streamId == 1),
      );

      final client = ServerStreamCaller<RpcString, RpcString>(
        transport: clientTransport,
        serviceName: 'S',
        methodName: 'M',
        requestCodec: codec,
        responseCodec: codec,
      );

      await client.send('x'.rpc);
      await expectLater(() => client.send('y'.rpc), throwsA(isA<StateError>()));

      await client.close();
      await server.close();
      await clientTransport.close();
      await serverTransport.close();
    });

    test('ClientStreamCaller.send throws after finishSending', () async {
      final (clientTransport, serverTransport) = RpcInMemoryTransport.pair();

      final server = ClientStreamResponder<RpcString, RpcString>(
        id: 1,
        transport: serverTransport,
        serviceName: 'S',
        methodName: 'M',
        requestCodec: codec,
        responseCodec: codec,
        handler: (requests) async => 'ok'.rpc,
      );
      server.bindToMessageStream(
        serverTransport.incomingMessages.where((m) => m.streamId == 1),
      );

      final client = ClientStreamCaller<RpcString, RpcString>(
        transport: clientTransport,
        serviceName: 'S',
        methodName: 'M',
        requestCodec: codec,
        responseCodec: codec,
      );

      await client.finishSending();
      await expectLater(() => client.send('x'.rpc), throwsA(isA<StateError>()));

      await client.close();
      await server.close();
      await clientTransport.close();
      await serverTransport.close();
    });

    test('ClientStreamCaller.finishSending throws when called twice', () async {
      final (clientTransport, serverTransport) = RpcInMemoryTransport.pair();

      final server = ClientStreamResponder<RpcString, RpcString>(
        id: 1,
        transport: serverTransport,
        serviceName: 'S',
        methodName: 'M',
        requestCodec: codec,
        responseCodec: codec,
        handler: (requests) async => 'ok'.rpc,
      );
      server.bindToMessageStream(
        serverTransport.incomingMessages.where((m) => m.streamId == 1),
      );

      final client = ClientStreamCaller<RpcString, RpcString>(
        transport: clientTransport,
        serviceName: 'S',
        methodName: 'M',
        requestCodec: codec,
        responseCodec: codec,
      );

      await client.finishSending();
      await expectLater(
        () => client.finishSending(),
        throwsA(isA<StateError>()),
      );

      await client.close();
      await server.close();
      await clientTransport.close();
      await serverTransport.close();
    });

    test('ClientStreamCaller errors on OK trailer without payload', () async {
      final (clientTransport, serverTransport) = RpcInMemoryTransport.pair();

      // Emulate a server that ends the stream with OK but no payload.
      serverTransport.incomingMessages.listen((message) async {
        if (message.isMetadataOnly && message.metadata?.methodPath == '/S/M') {
          await serverTransport.sendMetadata(
            message.streamId,
            RpcMetadata.forTrailer(RpcStatus.ok),
            endStream: true,
          );
        }
      });

      final client = ClientStreamCaller<RpcString, RpcString>(
        transport: clientTransport,
        serviceName: 'S',
        methodName: 'M',
        requestCodec: codec,
        responseCodec: codec,
      );

      await client.send('x'.rpc);
      await expectLater(
        () => client.finishSending().timeout(const Duration(seconds: 2)),
        throwsA(isA<Exception>()),
      );

      await client.close();
      await clientTransport.close();
      await serverTransport.close();
    });

    test('BidirectionalStreamCaller validates zero-copy requirements',
        () async {
      final (clientTransport, serverTransport) = RpcInMemoryTransport.pair();
      final transport = NoZeroCopyTransport(clientTransport);
      expect(
        () => BidirectionalStreamCaller<RpcString, RpcString>(
          transport: transport,
          serviceName: 'S',
          methodName: 'M',
          // null codecs => request zero-copy
        ),
        throwsArgumentError,
      );

      await clientTransport.close();
      await serverTransport.close();
    });
  });
}
