// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';
import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

void main() {
  group('Server Stream', () {
    final serializer = RpcCodec(RpcString.fromJson);

    group('ServerStreamClient', () {
      test('one request, many answers', () async {
        // Arrange
        final (clientTransport, serverTransport) = RpcInMemoryTransport.pair();
        final receivedRequests = <RpcString>[];

        final server = ServerStreamResponder<RpcString, RpcString>(
          id: 1,
          transport: serverTransport,
          serviceName: 'TestService',
          methodName: 'TestMethod',
          requestCodec: serializer,
          responseCodec: serializer,
          handler: (request) async* {
            receivedRequests.add(request);
            yield 'Response 1 for: $request'.rpc;
            await Future<void>.delayed(Duration(milliseconds: 1));
            yield 'Response 2 for: $request'.rpc;
            await Future<void>.delayed(Duration(milliseconds: 1));
            yield 'Response 3 for: $request'.rpc;
          },
        );

        // IMPORTANT: bind the server to the message stream for streamId = 1.
        server.bindToMessageStream(
          serverTransport.incomingMessages.where((msg) => msg.streamId == 1),
        );

        final client = ServerStreamCaller<RpcString, RpcString>(
          transport: clientTransport,
          serviceName: 'TestService',
          methodName: 'TestMethod',
          requestCodec: serializer,
          responseCodec: serializer,
        );

        // Act
        final receivedResponses = await client
            .call('test request'.rpc)
            .toList();

        // Assert
        expect(receivedResponses.length, equals(3));
        expect(
          receivedResponses[0],
          equals('Response 1 for: test request'.rpc),
        );
        expect(
          receivedResponses[1],
          equals('Response 2 for: test request'.rpc),
        );
        expect(
          receivedResponses[2],
          equals('Response 3 for: test request'.rpc),
        );
        expect(receivedRequests.length, equals(1));
        expect(receivedRequests.first, equals('test request'.rpc));

        // Cleanup
        await client.close();
        await server.close();
      });

      test('one request and no answers at all', () async {
        // Arrange
        final (clientTransport, serverTransport) = RpcInMemoryTransport.pair();

        final server = ServerStreamResponder<RpcString, RpcString>(
          id: 1,
          transport: serverTransport,
          serviceName: 'TestService',
          methodName: 'TestMethod',
          requestCodec: serializer,
          responseCodec: serializer,
          handler: (request) {
            return Stream.empty();
          },
        );

        // IMPORTANT: bind the server to the message stream for streamId = 1.
        server.bindToMessageStream(
          serverTransport.incomingMessages.where((msg) => msg.streamId == 1),
        );

        final client = ServerStreamCaller<RpcString, RpcString>(
          transport: clientTransport,
          serviceName: 'TestService',
          methodName: 'TestMethod',
          requestCodec: serializer,
          responseCodec: serializer,
        );

        var streamCompleted = false;
        final completer = Completer<void>();
        final subscription = client.responses.listen(
          (message) {},
          onDone: () {
            streamCompleted = true;
            completer.complete();
          },
        );

        // Act
        await client.send('test request'.rpc);

        // Wait for the stream to finish, with a timeout.
        await completer.future.timeout(Duration(seconds: 5));

        // Assert
        expect(streamCompleted, isTrue);

        // Cleanup
        await subscription.cancel();
        await client.close();
        await server.close();
      });

      test('throws when the server fails', () async {
        // Arrange
        final (clientTransport, serverTransport) = RpcInMemoryTransport.pair();

        final server = ServerStreamResponder<RpcString, RpcString>(
          id: 1,
          transport: serverTransport,
          serviceName: 'TestService',
          methodName: 'TestMethod',
          requestCodec: serializer,
          responseCodec: serializer,
          handler: (request) {
            // Throw synchronously.
            throw Exception('Server error');
          },
        );

        // IMPORTANT: bind the server to the message stream for streamId = 1.
        server.bindToMessageStream(
          serverTransport.incomingMessages.where((msg) => msg.streamId == 1),
        );

        final client = ServerStreamCaller<RpcString, RpcString>(
          transport: clientTransport,
          serviceName: 'TestService',
          methodName: 'TestMethod',
          requestCodec: serializer,
          responseCodec: serializer,
        );

        // Act & Assert
        await client.send('test request'.rpc);

        final response = await client.responses.first.timeout(
          Duration(seconds: 5),
        );

        // The trailer must carry the error.
        expect(response.isMetadataOnly, isTrue);
        expect(response.metadata, isNotNull);

        final grpcStatus = response.metadata!.getHeaderValue(
          RpcHeaders.grpcStatus,
        );
        expect(grpcStatus, isNotNull);
        expect(
          grpcStatus,
          isNot(equals('0')),
          reason: 'the gRPC status must say error, not 0',
        );

        // Cleanup
        await client.close();
        await server.close();
      });

      test('the answer stream ends cleanly', () async {
        // Arrange
        final (clientTransport, serverTransport) = RpcInMemoryTransport.pair();

        final server = ServerStreamResponder<RpcString, RpcString>(
          id: 1,
          transport: serverTransport,
          serviceName: 'TestService',
          methodName: 'TestMethod',
          requestCodec: serializer,
          responseCodec: serializer,
          handler: (request) async* {
            yield 'response1'.rpc;
            yield 'response2'.rpc;
          },
        );

        // IMPORTANT: bind the server to the message stream for streamId = 1.
        server.bindToMessageStream(
          serverTransport.incomingMessages.where((msg) => msg.streamId == 1),
        );

        final client = ServerStreamCaller<RpcString, RpcString>(
          transport: clientTransport,
          serviceName: 'TestService',
          methodName: 'TestMethod',
          requestCodec: serializer,
          responseCodec: serializer,
        );

        var streamCompleted = false;
        final completer = Completer<void>();
        final subscription = client.responses.listen(
          (message) {},
          onDone: () {
            streamCompleted = true;
            completer.complete();
          },
        );

        // Act
        await client.send('test request'.rpc);

        // Wait for the stream to finish, with a timeout.
        await completer.future.timeout(Duration(seconds: 5));

        // Assert
        expect(streamCompleted, isTrue);

        // Cleanup
        await subscription.cancel();
        await client.close();
        await server.close();
      });

      // NOTE: close() behavior is exercised by other tests in this suite.
    });

    group('ServerStreamServer', () {
      test('the responder takes one request and answers many', () async {
        // Arrange
        final (clientTransport, serverTransport) = RpcInMemoryTransport.pair();
        final receivedRequests = <RpcString>[];

        final server = ServerStreamResponder<RpcString, RpcString>(
          id: 1,
          transport: serverTransport,
          serviceName: 'TestService',
          methodName: 'TestMethod',
          requestCodec: serializer,
          responseCodec: serializer,
          handler: (request) async* {
            receivedRequests.add(request);

            // Send several answers.
            yield 'Response 1 for: $request'.rpc;
            yield 'Response 2 for: $request'.rpc;
            yield 'Response 3 for: $request'.rpc;
          },
        );

        // IMPORTANT: bind the server to the message stream for streamId = 1.
        server.bindToMessageStream(
          serverTransport.incomingMessages.where((msg) => msg.streamId == 1),
        );

        final client = ServerStreamCaller<RpcString, RpcString>(
          transport: clientTransport,
          serviceName: 'TestService',
          methodName: 'TestMethod',
          requestCodec: serializer,
          responseCodec: serializer,
        );

        final receivedResponses = <RpcString>[];
        final subscription = client.responses.listen((message) {
          if (!message.isMetadataOnly && message.payload != null) {
            receivedResponses.add(message.payload!);
          }
        });

        // Act
        await client.send('Hello Server'.rpc);
        await subscription.asFuture<void>();

        // Assert
        expect(receivedRequests.length, equals(1));
        expect(receivedRequests.first, equals('Hello Server'.rpc));
        expect(receivedResponses.length, equals(3));
        expect(
          receivedResponses[0],
          equals('Response 1 for: Hello Server'.rpc),
        );
        expect(
          receivedResponses[1],
          equals('Response 2 for: Hello Server'.rpc),
        );
        expect(
          receivedResponses[2],
          equals('Response 3 for: Hello Server'.rpc),
        );

        // Cleanup
        await client.close();
        await server.close();
      });

      test('a handler that throws is reported', () async {
        // Arrange
        final (clientTransport, serverTransport) = RpcInMemoryTransport.pair();

        final server = ServerStreamResponder<RpcString, RpcString>(
          id: 1,
          transport: serverTransport,
          serviceName: 'TestService',
          methodName: 'TestMethod',
          requestCodec: serializer,
          responseCodec: serializer,
          handler: (request) {
            // Throw synchronously.
            throw Exception('Handler error');
          },
        );

        // IMPORTANT: bind the server to the message stream for streamId = 1.
        server.bindToMessageStream(
          serverTransport.incomingMessages.where((msg) => msg.streamId == 1),
        );

        final client = ServerStreamCaller<RpcString, RpcString>(
          transport: clientTransport,
          serviceName: 'TestService',
          methodName: 'TestMethod',
          requestCodec: serializer,
          responseCodec: serializer,
        );

        // Act & Assert
        await client.send('test request'.rpc);

        final response = await client.responses.first.timeout(
          Duration(seconds: 5),
        );

        // The trailer must carry the error.
        expect(response.isMetadataOnly, isTrue);
        expect(response.metadata, isNotNull);

        final grpcStatus = response.metadata!.getHeaderValue(
          RpcHeaders.grpcStatus,
        );
        expect(grpcStatus, isNotNull);
        expect(
          grpcStatus,
          isNot(equals('0')),
          reason: 'the gRPC status must say error',
        );

        // Cleanup
        await client.close();
        await server.close();
      });

      test('a server answers only its own method', () async {
        // Arrange
        final (clientTransport, serverTransport) = RpcInMemoryTransport.pair();
        var handlerCallCount = 0;

        final server = ServerStreamResponder<RpcString, RpcString>(
          id: 1,
          transport: serverTransport,
          serviceName: 'TestService',
          methodName: 'SpecificMethod',
          requestCodec: serializer,
          responseCodec: serializer,
          handler: (request) async* {
            handlerCallCount++;
          },
        );

        // IMPORTANT: bind the server to the message stream for streamId = 1.
        server.bindToMessageStream(
          serverTransport.incomingMessages.where((msg) => msg.streamId == 1),
        );

        final correctClient = ServerStreamCaller<RpcString, RpcString>(
          transport: clientTransport,
          serviceName: 'TestService',
          methodName: 'SpecificMethod',
          requestCodec: serializer,
          responseCodec: serializer,
        );

        final incorrectClient = ServerStreamCaller<RpcString, RpcString>(
          transport: clientTransport,
          serviceName: 'TestService',
          methodName: 'DifferentMethod',
          requestCodec: serializer,
          responseCodec: serializer,
        );

        // Act
        await correctClient.send('correct request'.rpc);
        try {
          await incorrectClient.send('incorrect request'.rpc);
        } catch (e) {
          // The wrong method may well error.
        }

        // Assert
        expect(handlerCallCount, equals(1));

        // Cleanup
        await correctClient.close();
        await incorrectClient.close();
        await server.close();
      });

      test('an error ends the stream as an error', () async {
        // Arrange
        final (clientTransport, serverTransport) = RpcInMemoryTransport.pair();

        // A controller, so the test drives the stream.
        final controller = StreamController<RpcString>();

        final server = ServerStreamResponder<RpcString, RpcString>(
          id: 1,
          transport: serverTransport,
          serviceName: 'TestService',
          methodName: 'TestMethod',
          requestCodec: serializer,
          responseCodec: serializer,
          handler: (request) {
            // One answer, then an error on the stream.
            Future.microtask(() {
              controller.add('First response'.rpc);
              controller.addError(Exception('Test error message'));
              controller.close();
            });
            return controller.stream;
          },
        );

        // IMPORTANT: bind the server to the message stream for streamId = 1.
        server.bindToMessageStream(
          serverTransport.incomingMessages.where((msg) => msg.streamId == 1),
        );

        final client = ServerStreamCaller<RpcString, RpcString>(
          transport: clientTransport,
          serviceName: 'TestService',
          methodName: 'TestMethod',
          requestCodec: serializer,
          responseCodec: serializer,
        );

        // Act & Assert
        await client.send('test request'.rpc);

        // The raw `responses` stream forwards the data message(s) but surfaces
        // a non-OK grpc-status trailer as an RpcStatusException error rather
        // than completing silently. Collect forwarded messages and capture the
        // terminal error.
        final received = <RpcMessage<RpcString>>[];
        Object? caught;
        try {
          await for (final r in client.responses.timeout(
            Duration(seconds: 5),
          )) {
            received.add(r);
          }
        } catch (e) {
          caught = e;
        }

        // At least the data message must have been forwarded before the error.
        expect(received.length, greaterThanOrEqualTo(1));

        // The non-OK trailer must surface as an RpcStatusException error.
        expect(
          caught,
          isA<RpcStatusException>(),
          reason:
              'a gRPC error status must surface as a stream error, '
              'not as an ordinary close',
        );

        // Cleanup
        await client.close();
        await server.close();
      });

      // NOTE: close() behavior is exercised by other tests in this suite.
    });

    group('integration', () {
      test('a full server-streaming round', () async {
        // Arrange
        final (clientTransport, serverTransport) = RpcInMemoryTransport.pair();

        final server = ServerStreamResponder<RpcString, RpcString>(
          id: 1,
          transport: serverTransport,
          serviceName: 'NumberService',
          methodName: 'GenerateNumbers',
          requestCodec: serializer,
          responseCodec: serializer,
          handler: (request) async* {
            final count = int.tryParse(request.value) ?? 3;
            for (int i = 1; i <= count; i++) {
              yield 'Number $i'.rpc;
            }
          },
        );

        // IMPORTANT: bind the server to the message stream for streamId = 1.
        server.bindToMessageStream(
          serverTransport.incomingMessages.where((msg) => msg.streamId == 1),
        );

        final client = ServerStreamCaller<RpcString, RpcString>(
          transport: clientTransport,
          serviceName: 'NumberService',
          methodName: 'GenerateNumbers',
          requestCodec: serializer,
          responseCodec: serializer,
        );

        final receivedNumbers = <RpcString>[];
        var streamCompleted = false;
        final completer = Completer<void>();

        final subscription = client.responses.listen(
          (message) {
            if (!message.isMetadataOnly && message.payload != null) {
              receivedNumbers.add(message.payload!);
            }
          },
          onDone: () {
            streamCompleted = true;
            completer.complete();
          },
        );

        // Act
        await client.send('5'.rpc);

        // Wait for the stream to finish, with a timeout.
        await completer.future.timeout(Duration(seconds: 5));

        // Assert
        expect(receivedNumbers.length, equals(5));
        expect(receivedNumbers[0], equals('Number 1'.rpc));
        expect(receivedNumbers[4], equals('Number 5'.rpc));
        expect(streamCompleted, isTrue);

        // Cleanup
        await subscription.cancel();
        await client.close();
        await server.close();
      });

      test('a large number of answers', () async {
        // Arrange
        final (clientTransport, serverTransport) = RpcInMemoryTransport.pair();

        final server = ServerStreamResponder<RpcString, RpcString>(
          id: 1,
          transport: serverTransport,
          serviceName: 'StreamService',
          methodName: 'LargeStream',
          requestCodec: serializer,
          responseCodec: serializer,
          handler: (request) async* {
            const responseCount = 50;
            for (int i = 0; i < responseCount; i++) {
              yield 'Response $i'.rpc;
            }
          },
        );

        // IMPORTANT: bind the server to the message stream for streamId = 1.
        server.bindToMessageStream(
          serverTransport.incomingMessages.where((msg) => msg.streamId == 1),
        );

        final client = ServerStreamCaller<RpcString, RpcString>(
          transport: clientTransport,
          serviceName: 'StreamService',
          methodName: 'LargeStream',
          requestCodec: serializer,
          responseCodec: serializer,
        );

        final receivedResponses = <RpcString>[];
        final subscription = client.responses.listen((message) {
          if (!message.isMetadataOnly && message.payload != null) {
            receivedResponses.add(message.payload!);
          }
        });

        // Act
        await client.send('start stream'.rpc);
        await subscription.asFuture<void>();

        // Assert
        expect(receivedResponses.length, equals(50));
        expect(receivedResponses.first, equals('Response 0'.rpc));
        expect(receivedResponses.last, equals('Response 49'.rpc));

        // Cleanup
        await client.close();
        await server.close();
      });
    });
  });
}
