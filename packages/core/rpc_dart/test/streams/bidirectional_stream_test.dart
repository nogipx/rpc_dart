// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';
import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

void main() {
  group('Bidirectional Stream', () {
    final serializer = RpcCodec(RpcString.fromJson);
    group('BidirectionalStreamClient', () {
      test('the caller sends and receives both ways', () async {
        // Arrange
        final (clientTransport, serverTransport) = RpcInMemoryTransport.pair();

        final server = BidirectionalStreamResponder<RpcString, RpcString>(
          id: 1,
          transport: serverTransport,
          serviceName: 'TestService',
          methodName: 'TestMethod',
          requestCodec: serializer,
          responseCodec: serializer,
        );

        // IMPORTANT: bind the server to the message stream for streamId = 1.
        server.bindToMessageStream(
          serverTransport.incomingMessages.where((msg) => msg.streamId == 1),
        );

        final client = BidirectionalStreamCaller<RpcString, RpcString>(
          transport: clientTransport,
          serviceName: 'TestService',
          methodName: 'TestMethod',
          requestCodec: serializer,
          responseCodec: serializer,
        );

        final receivedRequests = <RpcString>[];
        final receivedResponses = <RpcString>[];

        // Wire up the server side.
        server.requests.listen((request) async {
          receivedRequests.add(request);
          await server.send('Echo: $request'.rpc);
        });

        // Wire up the client side.
        client.responses.listen((message) {
          if (!message.isMetadataOnly && message.payload != null) {
            receivedResponses.add(message.payload!);
          }
        });

        // Act
        await client.send('Hello'.rpc);
        await client.send('World'.rpc);

        // Wait for the messages to be handled.
        while (receivedResponses.length < 2) {
          await Future<void>.delayed(Duration(milliseconds: 1));
        }

        // Assert
        expect(receivedRequests.length, equals(2));
        expect(receivedRequests, equals(['Hello'.rpc, 'World'.rpc]));
        expect(receivedResponses.length, equals(2));
        expect(
          receivedResponses,
          equals(['Echo: Hello'.rpc, 'Echo: World'.rpc]),
        );

        // Cleanup
        await client.close();
        await server.close();
      });
    });

    group('BidirectionalStreamServer', () {
      test('the responder receives and sends both ways', () async {
        // Arrange
        final (clientTransport, serverTransport) = RpcInMemoryTransport.pair();

        final server = BidirectionalStreamResponder<RpcString, RpcString>(
          id: 1,
          transport: serverTransport,
          serviceName: 'TestService',
          methodName: 'TestMethod',
          requestCodec: serializer,
          responseCodec: serializer,
        );

        // IMPORTANT: bind the server to the message stream for streamId = 1.
        server.bindToMessageStream(
          serverTransport.incomingMessages.where((msg) => msg.streamId == 1),
        );

        final client = BidirectionalStreamCaller<RpcString, RpcString>(
          transport: clientTransport,
          serviceName: 'TestService',
          methodName: 'TestMethod',
          requestCodec: serializer,
          responseCodec: serializer,
        );

        final serverReceivedRequests = <RpcString>[];
        final clientReceivedResponses = <RpcString>[];

        // The server's logic.
        server.requests.listen((request) async {
          serverReceivedRequests.add(request);
          await server.send('Server processed: $request'.rpc);
        });

        // The client's logic.
        client.responses.listen((message) {
          if (!message.isMetadataOnly && message.payload != null) {
            clientReceivedResponses.add(message.payload!);
          }
        });

        // Act
        await client.send('Request 1'.rpc);
        await client.send('Request 2'.rpc);

        // Let it run.
        while (clientReceivedResponses.length < 2) {
          await Future<void>.delayed(Duration(milliseconds: 1));
        }

        // Assert
        expect(serverReceivedRequests.length, equals(2));
        expect(
          serverReceivedRequests,
          equals(['Request 1'.rpc, 'Request 2'.rpc]),
        );
        expect(clientReceivedResponses.length, equals(2));
        expect(
          clientReceivedResponses,
          contains('Server processed: Request 1'.rpc),
        );
        expect(
          clientReceivedResponses,
          contains('Server processed: Request 2'.rpc),
        );

        // Cleanup
        await client.close();
        await server.close();
      });

      test('a server answers only its own method', () async {
        // Arrange
        final (clientTransport, serverTransport) = RpcInMemoryTransport.pair();
        var handlerCallCount = 0;

        final server = BidirectionalStreamResponder<RpcString, RpcString>(
          id: 1,
          transport: serverTransport,
          serviceName: 'TestService',
          methodName: 'SpecificMethod',
          requestCodec: serializer,
          responseCodec: serializer,
        );

        // IMPORTANT: bind the server to the message stream for streamId = 1.
        server.bindToMessageStream(
          serverTransport.incomingMessages.where((msg) => msg.streamId == 1),
        );

        server.requests.listen((_) => handlerCallCount++);

        final correctClient = BidirectionalStreamCaller<RpcString, RpcString>(
          transport: clientTransport,
          serviceName: 'TestService',
          methodName: 'SpecificMethod',
          requestCodec: serializer,
          responseCodec: serializer,
        );

        final incorrectClient = BidirectionalStreamCaller<RpcString, RpcString>(
          transport: clientTransport,
          serviceName: 'TestService',
          methodName: 'DifferentMethod',
          requestCodec: serializer,
          responseCodec: serializer,
        );

        // Act
        await correctClient.send('correct request'.rpc);
        // A pause, so the request has time to be handled.
        await Future<void>.delayed(Duration(milliseconds: 1));

        await incorrectClient.send('incorrect request'.rpc);
        // A pause, so the request has time to be handled.
        await Future<void>.delayed(Duration(milliseconds: 1));

        // Wait for every request to be handled.
        await Future<void>.delayed(Duration(milliseconds: 1));

        // Assert
        expect(handlerCallCount, equals(1));

        // Cleanup
        await correctClient.close();
        await incorrectClient.close();
        await server.close();
      });
    });

    group('integration', () {
      test('a full bidirectional round', () async {
        // Arrange
        final (clientTransport, serverTransport) = RpcInMemoryTransport.pair();

        final server = BidirectionalStreamResponder<RpcString, RpcString>(
          id: 1,
          transport: serverTransport,
          serviceName: 'ChatService',
          methodName: 'Chat',
          requestCodec: serializer,
          responseCodec: serializer,
        );

        // IMPORTANT: bind the server to the message stream for streamId = 1.
        server.bindToMessageStream(
          serverTransport.incomingMessages.where((msg) => msg.streamId == 1),
        );

        final client = BidirectionalStreamCaller<RpcString, RpcString>(
          transport: clientTransport,
          serviceName: 'ChatService',
          methodName: 'Chat',
          requestCodec: serializer,
          responseCodec: serializer,
        );

        final serverMessages = <RpcString>[];
        final clientMessages = <RpcString>[];

        // The server.
        server.requests.listen((request) async {
          serverMessages.add(request);

          if (request.value.startsWith('ping')) {
            await server.send('pong'.rpc);
          } else {
            await server.send('echo: $request'.rpc);
          }
        });

        // The client.
        client.responses.listen((message) {
          if (!message.isMetadataOnly && message.payload != null) {
            clientMessages.add(message.payload!);
          }
        });

        // Act
        await client.send('ping 1'.rpc);
        await client.send('hello world'.rpc);
        await client.send('ping 2'.rpc);

        // Wait for every message to be handled.
        while (clientMessages.length < 3) {
          await Future<void>.delayed(Duration(milliseconds: 1));
        }

        // Assert
        expect(serverMessages.length, equals(3));
        expect(
          serverMessages,
          equals(['ping 1'.rpc, 'hello world'.rpc, 'ping 2'.rpc]),
        );

        expect(clientMessages.length, equals(3));
        expect(clientMessages, contains('pong'.rpc));
        expect(clientMessages, contains('echo: hello world'.rpc));

        // Cleanup
        await client.close();
        await server.close();
      });

      test('a large number of messages', () async {
        // Arrange
        final (clientTransport, serverTransport) = RpcInMemoryTransport.pair();

        final server = BidirectionalStreamResponder<RpcString, RpcString>(
          id: 1,
          transport: serverTransport,
          serviceName: 'HighVolumeService',
          methodName: 'Process',
          requestCodec: serializer,
          responseCodec: serializer,
        );

        // IMPORTANT: bind the server to the message stream for streamId = 1.
        server.bindToMessageStream(
          serverTransport.incomingMessages.where((msg) => msg.streamId == 1),
        );

        final client = BidirectionalStreamCaller<RpcString, RpcString>(
          transport: clientTransport,
          serviceName: 'HighVolumeService',
          methodName: 'Process',
          requestCodec: serializer,
          responseCodec: serializer,
        );

        final receivedResponses = <RpcString>[];

        server.requests.listen((request) async {
          await server.send('processed: $request'.rpc);
        });

        client.responses.listen((message) {
          if (!message.isMetadataOnly && message.payload != null) {
            receivedResponses.add(message.payload!);
          }
        });

        // Act
        const messageCount = 50;
        for (int i = 0; i < messageCount; i++) {
          await client.send('message_$i'.rpc);
        }

        // Wait for every message to be handled.
        while (receivedResponses.length < messageCount) {
          await Future<void>.delayed(Duration(milliseconds: 1));
        }

        // Assert
        expect(receivedResponses.length, equals(messageCount));
        expect(receivedResponses.first, equals('processed: message_0'.rpc));
        expect(
          receivedResponses.last,
          equals('processed: message_${messageCount - 1}'.rpc),
        );

        // Cleanup
        await client.close();
        await server.close();
      });
    });
  });
}
