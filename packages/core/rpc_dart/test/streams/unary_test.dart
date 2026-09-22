// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';
import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

/// Builds a transport pair for these tests.
(IRpcTransport, IRpcTransport) createTransportPair() =>
    RpcInMemoryTransport.pair();

void main() {
  group('Unary RPC', () {
    final serializer = RpcCodec(RpcString.fromJson);

    group('UnaryClient', () {
      test('sends a request and gets an answer', () async {
        // Arrange
        final (clientTransport, serverTransport) = createTransportPair();
        final receivedRequests = <RpcString>[];

        final server = UnaryResponder<RpcString, RpcString>(
          transport: serverTransport,
          serviceName: 'TestService',
          methodName: 'TestMethod',
          requestCodec: serializer,
          responseCodec: serializer,
          handler: (request) {
            receivedRequests.add(request);
            return 'Echo: $request'.rpc;
          },
        );

        final client = UnaryCaller<RpcString, RpcString>(
          transport: clientTransport,
          serviceName: 'TestService',
          methodName: 'TestMethod',
          requestCodec: serializer,
          responseCodec: serializer,
          logger: LogScope.noop,
        );

        // Act
        final response = await client.call('test request'.rpc);

        // Assert
        expect(response, equals('Echo: test request'.rpc));
        expect(receivedRequests.length, equals(1));
        expect(receivedRequests.first, equals('test request'.rpc));

        // Cleanup
        await client.close();
        await server.close();
      });

      test('throws when the server fails', () async {
        // Arrange
        final (clientTransport, serverTransport) = createTransportPair();

        final server = UnaryResponder<RpcString, RpcString>(
          transport: serverTransport,
          serviceName: 'TestService',
          methodName: 'TestMethod',
          requestCodec: serializer,
          responseCodec: serializer,
          handler: (request) {
            throw Exception('Internal server error');
          },
        );

        final client = UnaryCaller<RpcString, RpcString>(
          transport: clientTransport,
          serviceName: 'TestService',
          methodName: 'TestMethod',
          requestCodec: serializer,
          responseCodec: serializer,
          logger: LogScope.noop,
        );

        // Act & Assert
        await expectLater(
          client.call('test request'.rpc),
          throwsA(isA<RpcStatusException>()),
        );

        // Cleanup
        await client.close();
        await server.close();
      });

      test('applies the timeout to the request', () async {
        // Arrange
        final (clientTransport, serverTransport) = createTransportPair();

        final server = UnaryResponder<RpcString, RpcString>(
          transport: serverTransport,
          serviceName: 'TestService',
          methodName: 'TestMethod',
          requestCodec: serializer,
          responseCodec: serializer,
          handler: (request) async {
            // Longer than the timeout.
            await Future<void>.delayed(Duration(seconds: 1));
            return 'Delayed response'.rpc;
          },
        );

        final client = UnaryCaller<RpcString, RpcString>(
          transport: clientTransport,
          serviceName: 'TestService',
          methodName: 'TestMethod',
          requestCodec: serializer,
          responseCodec: serializer,
          logger: LogScope.noop,
        );

        // Act & Assert
        expect(
          () => client.call(
            'test request'.rpc,
            timeout: Duration(milliseconds: 1),
          ),
          throwsA(isA<TimeoutException>()),
        );

        // Cleanup
        await client.close();
        await server.close();
      });

      test('every call gets its own stream id', () async {
        // Arrange
        final (clientTransport, serverTransport) = createTransportPair();
        final receivedStreamIds = <int>[];

        // Watch the incoming stream ids.
        serverTransport.incomingMessages.listen((message) {
          if (message.isMetadataOnly) {
            receivedStreamIds.add(message.streamId);
          }
        });

        // A plain server.
        final server = UnaryResponder<RpcString, RpcString>(
          transport: serverTransport,
          serviceName: 'TestService',
          methodName: 'TestMethod',
          requestCodec: serializer,
          responseCodec: serializer,
          handler: (request) => 'Echo: $request'.rpc,
        );

        // Act: make several calls.
        final client = UnaryCaller<RpcString, RpcString>(
          transport: clientTransport,
          serviceName: 'TestService',
          methodName: 'TestMethod',
          requestCodec: serializer,
          responseCodec: serializer,
        );

        // Three calls, one after another.
        await client.call('request 1'.rpc);
        await client.call('request 2'.rpc);
        await client.call('request 3'.rpc);

        // Assert
        expect(receivedStreamIds.length, equals(3));
        expect(receivedStreamIds.toSet().length, equals(3)); // All distinct.

        // Cleanup
        await client.close();
        await server.close();
      });
    });

    group('UnaryServer', () {
      test('handles a request and sends an answer', () async {
        // Arrange
        final (clientTransport, serverTransport) = createTransportPair();

        final receivedRequests = <RpcString>[];

        final server = UnaryResponder<RpcString, RpcString>(
          transport: serverTransport,
          serviceName: 'TestService',
          methodName: 'TestMethod',
          requestCodec: serializer,
          responseCodec: serializer,
          handler: (request) {
            receivedRequests.add(request);
            return 'Echo: $request'.rpc;
          },
        );

        final client = UnaryCaller<RpcString, RpcString>(
          transport: clientTransport,
          serviceName: 'TestService',
          methodName: 'TestMethod',
          requestCodec: serializer,
          responseCodec: serializer,
        );

        // Act
        final response = await client.call('Hello Server'.rpc);

        // Assert
        expect(response, equals('Echo: Hello Server'.rpc));
        expect(receivedRequests.length, equals(1));
        expect(receivedRequests.first, equals('Hello Server'.rpc));

        // Cleanup
        await client.close();
        await server.close();
      });

      test('a handler that throws sends an error back', () async {
        // Arrange
        final (clientTransport, serverTransport) = createTransportPair();

        final server = UnaryResponder<RpcString, RpcString>(
          transport: serverTransport,
          serviceName: 'TestService',
          methodName: 'TestMethod',
          requestCodec: serializer,
          responseCodec: serializer,
          handler: (request) {
            throw Exception('Handler error');
          },
        );

        final client = UnaryCaller<RpcString, RpcString>(
          transport: clientTransport,
          serviceName: 'TestService',
          methodName: 'TestMethod',
          requestCodec: serializer,
          responseCodec: serializer,
        );

        // Act & Assert
        await expectLater(
          client.call('test request'.rpc),
          throwsA(isA<RpcStatusException>()),
        );

        // Cleanup
        await client.close();
        await server.close();
      });

      test('a server answers only its own method', () async {
        // Arrange
        final (clientTransport, serverTransport) = createTransportPair();

        var handlerCallCount = 0;
        final receivedRequests = <RpcString>[];

        // A server bound to one method.
        final server = UnaryResponder<RpcString, RpcString>(
          transport: serverTransport,
          serviceName: 'TestService',
          methodName: 'SpecificMethod',
          requestCodec: serializer,
          responseCodec: serializer,
          handler: (request) {
            handlerCallCount++;
            receivedRequests.add(request);
            return 'response from SpecificMethod'.rpc;
          },
        );

        // A second server, on a different method.
        final otherServer = UnaryResponder<RpcString, RpcString>(
          transport: serverTransport,
          serviceName: 'TestService',
          methodName: 'DifferentMethod',
          requestCodec: serializer,
          responseCodec: serializer,
          handler: (request) {
            return 'response from DifferentMethod'.rpc;
          },
        );

        // A client for each method.
        final correctClient = UnaryCaller<RpcString, RpcString>(
          transport: clientTransport,
          serviceName: 'TestService',
          methodName: 'SpecificMethod',
          requestCodec: serializer,
          responseCodec: serializer,
        );

        final otherClient = UnaryCaller<RpcString, RpcString>(
          transport: clientTransport,
          serviceName: 'TestService',
          methodName: 'DifferentMethod',
          requestCodec: serializer,
          responseCodec: serializer,
        );

        // Act
        final response1 = await correctClient.call('correct request'.rpc);
        final response2 = await otherClient.call('other request'.rpc);

        // Assert
        expect(handlerCallCount, equals(1)); // Exactly one handler ran.
        expect(receivedRequests, equals(['correct request'.rpc]));
        expect(response1, equals('response from SpecificMethod'.rpc));
        expect(response2, equals('response from DifferentMethod'.rpc));

        // Cleanup
        await correctClient.close();
        await otherClient.close();
        await server.close();
        await otherServer.close();
      });
    });

    group('integration', () {
      test('a full request/answer round works', () async {
        // Arrange
        final (clientTransport, serverTransport) = createTransportPair();

        final server = UnaryResponder<RpcString, RpcString>(
          transport: serverTransport,
          serviceName: 'EchoService',
          methodName: 'Echo',
          requestCodec: serializer,
          responseCodec: serializer,
          handler: (request) => 'Echo: $request'.rpc,
        );

        final client = UnaryCaller<RpcString, RpcString>(
          transport: clientTransport,
          serviceName: 'EchoService',
          methodName: 'Echo',
          requestCodec: serializer,
          responseCodec: serializer,
        );

        // Act
        final response1 = await client.call('Hello'.rpc);
        final response2 = await client.call('World'.rpc);

        // Assert
        expect(response1, equals('Echo: Hello'.rpc));
        expect(response2, equals('Echo: World'.rpc));

        // Cleanup
        await client.close();
        await server.close();
      });

      test('several clients can share one server', () async {
        // Arrange
        final (clientTransport, serverTransport) = createTransportPair();

        var requestCount = 0;

        final server = UnaryResponder<RpcString, RpcString>(
          transport: serverTransport,
          serviceName: 'CounterService',
          methodName: 'Increment',
          requestCodec: serializer,
          responseCodec: serializer,
          handler: (request) {
            requestCount++;
            return 'Count: $requestCount'.rpc;
          },
        );

        // Act: several clients.
        final responses = <RpcString>[];
        for (int i = 0; i < 3; i++) {
          final client = UnaryCaller<RpcString, RpcString>(
            transport: clientTransport,
            serviceName: 'CounterService',
            methodName: 'Increment',
            requestCodec: serializer,
            responseCodec: serializer,
          );

          responses.add(await client.call('increment'.rpc));
          await client.close();
        }

        // Assert
        expect(responses.length, equals(3));
        expect(responses[0], equals('Count: 1'.rpc));
        expect(responses[1], equals('Count: 2'.rpc));
        expect(responses[2], equals('Count: 3'.rpc));

        // Cleanup
        await server.close();
      });
    });
  });
}
