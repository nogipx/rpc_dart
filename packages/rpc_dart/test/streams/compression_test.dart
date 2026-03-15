// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';
import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

void main() {
  final codec = RpcCodec(RpcString.fromJson);

  // A large-ish payload that benefits from compression.
  final largePayload = ('Hello gzip compression! ' * 50).rpc;

  group('Compression - Server Stream', () {
    test('server_compresses_responses_when_client_advertises_gzip', () async {
      final (clientTransport, serverTransport) = RpcInMemoryTransport.pair();

      // Server context: advertise that it accepts gzip → enables response compression.
      final serverContext = RpcContext.withHeaders({
        RpcConstants.grpcAcceptEncodingHeader: 'identity,gzip',
      });

      final server = ServerStreamResponder<RpcString, RpcString>(
        id: 1,
        transport: serverTransport,
        serviceName: 'TestService',
        methodName: 'TestMethod',
        requestCodec: codec,
        responseCodec: codec,
        context: serverContext,
        handler: (request) async* {
          yield largePayload;
          yield largePayload;
          yield largePayload;
        },
      );

      server.bindToMessageStream(
        serverTransport.incomingMessages.where((msg) => msg.streamId == 1),
      );

      final client = ServerStreamCaller<RpcString, RpcString>(
        transport: clientTransport,
        serviceName: 'TestService',
        methodName: 'TestMethod',
        requestCodec: codec,
        responseCodec: codec,
      );

      final responses = await client.call(largePayload).toList();

      expect(responses.length, equals(3));
      for (final r in responses) {
        expect(r, equals(largePayload));
      }

      await client.close();
      await server.close();
    });

    test('client_sends_compressed_request_server_stream_responds', () async {
      final (clientTransport, serverTransport) = RpcInMemoryTransport.pair();

      final server = ServerStreamResponder<RpcString, RpcString>(
        id: 1,
        transport: serverTransport,
        serviceName: 'TestService',
        methodName: 'TestMethod',
        requestCodec: codec,
        responseCodec: codec,
        handler: (request) async* {
          yield 'echo:${request.value}'.rpc;
        },
      );

      server.bindToMessageStream(
        serverTransport.incomingMessages.where((msg) => msg.streamId == 1),
      );

      // Client context: compress outgoing requests with gzip.
      final clientContext = RpcContext.withHeaders({
        RpcConstants.grpcEncodingHeader: 'gzip',
      });

      final client = ServerStreamCaller<RpcString, RpcString>(
        transport: clientTransport,
        serviceName: 'TestService',
        methodName: 'TestMethod',
        requestCodec: codec,
        responseCodec: codec,
        context: clientContext,
      );

      final responses = await client.call(largePayload).toList();

      expect(responses.length, equals(1));
      expect(responses.first, equals('echo:${largePayload.value}'.rpc));

      await client.close();
      await server.close();
    });
  });

  group('Compression - Client Stream', () {
    test('client_sends_compressed_requests_server_receives_correctly',
        () async {
      final (clientTransport, serverTransport) = RpcInMemoryTransport.pair();

      final server = ClientStreamResponder<RpcString, RpcString>(
        id: 1,
        transport: serverTransport,
        serviceName: 'TestService',
        methodName: 'TestMethod',
        requestCodec: codec,
        responseCodec: codec,
        handler: (requests) async {
          final all = await requests.toList();
          return 'count:${all.length}'.rpc;
        },
      );

      server.bindToMessageStream(
        serverTransport.incomingMessages.where((msg) => msg.streamId == 1),
      );

      // Client context: compress outgoing requests with gzip.
      final clientContext = RpcContext.withHeaders({
        RpcConstants.grpcEncodingHeader: 'gzip',
      });

      final client = ClientStreamCaller<RpcString, RpcString>(
        transport: clientTransport,
        serviceName: 'TestService',
        methodName: 'TestMethod',
        requestCodec: codec,
        responseCodec: codec,
        context: clientContext,
      );

      await client.send(largePayload);
      await client.send(largePayload);
      await client.send(largePayload);
      final response = await client.finishSending();

      expect(response, equals('count:3'.rpc));

      await server.close();
    });

    test('server_compresses_response_when_client_stream_advertises_gzip',
        () async {
      final (clientTransport, serverTransport) = RpcInMemoryTransport.pair();

      // Server context: advertise gzip acceptance → compress the single response.
      final serverContext = RpcContext.withHeaders({
        RpcConstants.grpcAcceptEncodingHeader: 'identity,gzip',
      });

      final server = ClientStreamResponder<RpcString, RpcString>(
        id: 1,
        transport: serverTransport,
        serviceName: 'TestService',
        methodName: 'TestMethod',
        requestCodec: codec,
        responseCodec: codec,
        context: serverContext,
        handler: (requests) async {
          final all = await requests.toList();
          return 'count:${all.length}'.rpc;
        },
      );

      server.bindToMessageStream(
        serverTransport.incomingMessages.where((msg) => msg.streamId == 1),
      );

      final client = ClientStreamCaller<RpcString, RpcString>(
        transport: clientTransport,
        serviceName: 'TestService',
        methodName: 'TestMethod',
        requestCodec: codec,
        responseCodec: codec,
      );

      await client.send('a'.rpc);
      await client.send('b'.rpc);
      final response = await client.finishSending();

      expect(response, equals('count:2'.rpc));

      await server.close();
    });
  });

  group('Compression - Bidirectional Stream', () {
    test('both_sides_compressed_bidirectional_round_trip', () async {
      final (clientTransport, serverTransport) = RpcInMemoryTransport.pair();

      // Server context: compress responses.
      final serverContext = RpcContext.withHeaders({
        RpcConstants.grpcAcceptEncodingHeader: 'identity,gzip',
      });

      final server = BidirectionalStreamResponder<RpcString, RpcString>(
        id: 1,
        transport: serverTransport,
        serviceName: 'TestService',
        methodName: 'TestMethod',
        requestCodec: codec,
        responseCodec: codec,
        context: serverContext,
      );

      server.bindToMessageStream(
        serverTransport.incomingMessages.where((msg) => msg.streamId == 1),
      );

      // Client context: compress requests.
      final clientContext = RpcContext.withHeaders({
        RpcConstants.grpcEncodingHeader: 'gzip',
      });

      final client = BidirectionalStreamCaller<RpcString, RpcString>(
        transport: clientTransport,
        serviceName: 'TestService',
        methodName: 'TestMethod',
        requestCodec: codec,
        responseCodec: codec,
        context: clientContext,
      );

      final receivedRequests = <RpcString>[];
      final receivedResponses = <RpcString>[];

      server.requests.listen((request) async {
        receivedRequests.add(request);
        await server.send('echo:${request.value}'.rpc);
      });

      client.responses.listen((message) {
        if (!message.isMetadataOnly && message.payload != null) {
          receivedResponses.add(message.payload!);
        }
      });

      await client.send(largePayload);
      await client.send(largePayload);

      while (receivedResponses.length < 2) {
        await Future.delayed(Duration(milliseconds: 1));
      }

      expect(receivedRequests.length, equals(2));
      expect(receivedRequests, equals([largePayload, largePayload]));
      expect(receivedResponses.length, equals(2));
      expect(
        receivedResponses,
        equals([
          'echo:${largePayload.value}'.rpc,
          'echo:${largePayload.value}'.rpc
        ]),
      );

      await client.close();
      await server.close();
    });

    test('uncompressed_bidirectional_still_works', () async {
      final (clientTransport, serverTransport) = RpcInMemoryTransport.pair();

      final server = BidirectionalStreamResponder<RpcString, RpcString>(
        id: 1,
        transport: serverTransport,
        serviceName: 'TestService',
        methodName: 'TestMethod',
        requestCodec: codec,
        responseCodec: codec,
      );

      server.bindToMessageStream(
        serverTransport.incomingMessages.where((msg) => msg.streamId == 1),
      );

      final client = BidirectionalStreamCaller<RpcString, RpcString>(
        transport: clientTransport,
        serviceName: 'TestService',
        methodName: 'TestMethod',
        requestCodec: codec,
        responseCodec: codec,
      );

      final receivedResponses = <RpcString>[];

      server.requests.listen((request) async {
        await server.send('echo:${request.value}'.rpc);
      });

      client.responses.listen((message) {
        if (!message.isMetadataOnly && message.payload != null) {
          receivedResponses.add(message.payload!);
        }
      });

      await client.send('ping'.rpc);

      while (receivedResponses.isEmpty) {
        await Future.delayed(Duration(milliseconds: 1));
      }

      expect(receivedResponses.first, equals('echo:ping'.rpc));

      await client.close();
      await server.close();
    });
  });
}
