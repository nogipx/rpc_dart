// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';
import 'dart:isolate';
import 'dart:math';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_isolate/rpc_dart_isolate.dart';
import 'package:test/test.dart';

// The models the zero-copy tests send.
class TestComplexObject {
  final int id;
  final String name;
  final Map<String, dynamic> metadata;
  final List<String> tags;
  final DateTime createdAt;
  final bool isActive;

  TestComplexObject({
    required this.id,
    required this.name,
    required this.metadata,
    required this.tags,
    required this.createdAt,
    required this.isActive,
  });

  @override
  String toString() {
    return 'TestComplexObject(id: $id, name: $name, metadata: $metadata, tags: $tags, createdAt: $createdAt, isActive: $isActive)';
  }
}

class TestLargeObject {
  final List<Map<String, dynamic>> data;

  TestLargeObject(this.data);

  static TestLargeObject generate(int size) {
    final random = Random();
    final data = List.generate(
      size,
      (index) => {
        'id': index,
        'value': random.nextDouble(),
        'text': 'Item $index with random data ${random.nextInt(1000)}',
        'nested': {
          'level1': {
            'level2': 'deep value $index',
            'array': List.generate(5, (i) => 'item_${index}_$i'),
          },
        },
      },
    );
    return TestLargeObject(data);
  }

  @override
  String toString() {
    return 'TestLargeObject(size: ${data.length})';
  }
}

@pragma('vm:entry-point')
void _transferableEchoServer(
  IRpcTransport transport,
  Map<String, dynamic> params,
) {
  transport.incomingMessages.listen((message) async {
    if (!message.isDirect || message.directPayload == null) return;
    final payload = message.directPayload;

    if (payload is TransferableTypedData) {
      final bytes = payload.materialize().asUint8List();
      final roundtrip = TransferableTypedData.fromList([bytes]);
      await transport.sendDirectObject(
        message.streamId,
        roundtrip,
        endStream: true,
      );
    }
  });
}

void main() {
  group('RpcIsolateTransport', () {
    group('TransferableTypedData', () {
      test(
        'directObject carries TransferableTypedData there and back, no copies',
        () async {
          final result = await RpcIsolateTransport.spawn(
            entrypoint: _transferableEchoServer,
            customParams: const {},
            isolateId: 'transferable-echo',
          );

          final transport = result.transport;
          final streamId = transport.createStream();

          final original = Uint8List.fromList(
            List<int>.generate(256, (i) => i),
          );
          final transfer = TransferableTypedData.fromList([original]);

          final responseFuture = transport
              .getMessagesForStream(streamId)
              .where((msg) => msg.isDirect && msg.directPayload != null)
              .map((msg) => msg.directPayload)
              .cast<TransferableTypedData>()
              .first
              .timeout(const Duration(seconds: 2));

          await transport.sendDirectObject(streamId, transfer);
          final receivedTransfer = await responseFuture;

          final roundtrip = receivedTransfer.materialize().asUint8List();
          expect(roundtrip, orderedEquals(original));

          result.kill();
        },
      );
    });

    group('spawn factory', () {
      test('spawns an isolate and returns a transport', () async {
        // Arrange & Act
        final result = await RpcIsolateTransport.spawn(
          entrypoint: _testEchoServer,
          customParams: {'test': 'value'},
          isolateId: 'test-isolate',
          debugName: 'Test Echo Server',
        );

        // Assert
        expect(result.transport, isA<IRpcTransport>());
        expect(result.kill, isA<Function>());

        // Cleanup
        result.kill();
      });

      test('passes the custom params into the isolate', () async {
        // Arrange
        final testParams = {
          'serviceName': 'TestService',
          'responsePrefix': '[TEST]: ',
        };

        // Act
        final result = await RpcIsolateTransport.spawn(
          entrypoint: _testParameterServer,
          customParams: testParams,
          isolateId: 'param-test',
        );

        final transport = result.transport;

        // Check that we can talk to the isolate.
        final streamId = transport.createStream();
        final receivedMessages = <RpcTransportMessage>[];

        transport.incomingMessages.listen(receivedMessages.add);

        // Send a test message.
        await transport.sendMessage(
          streamId,
          Uint8List.fromList('test message'.codeUnits),
        );

        // Let the isolate handle it.
        await Future<void>.delayed(Duration(milliseconds: 200));

        // Assert
        expect(receivedMessages.length, greaterThan(0));

        // Cleanup
        result.kill();
      });

      test('surfaces an error raised while the isolate starts', () async {
        // A worker that throws during startup must make spawn() fail fast
        // (surfacing the cause) instead of returning a silently-dead transport
        // or hanging forever.
        await expectLater(
          RpcIsolateTransport.spawn(
            entrypoint: _faultyServer,
            customParams: {},
            isolateId: 'faulty-isolate',
            startupTimeout: const Duration(seconds: 5),
          ),
          throwsA(
            predicate((e) => e.toString().contains('Intentional server error')),
          ),
        );
      });
    });

    group('createStream', () {
      test('creates unique stream ids', () async {
        // Arrange
        final result = await RpcIsolateTransport.spawn(
          entrypoint: _testEchoServer,
          customParams: {},
          isolateId: 'stream-test',
        );

        final transport = result.transport;

        // Act
        final streamId1 = transport.createStream();
        final streamId2 = transport.createStream();
        final streamId3 = transport.createStream();

        // Assert
        expect(streamId1, isNot(equals(streamId2)));
        expect(streamId2, isNot(equals(streamId3)));
        expect(streamId1, isNot(equals(streamId3)));

        // Cleanup
        result.kill();
      });

      test('generates odd numbers on the client side', () async {
        // Arrange
        final result = await RpcIsolateTransport.spawn(
          entrypoint: _testEchoServer,
          customParams: {},
          isolateId: 'odd-stream-test',
        );

        final transport = result.transport;

        // Act
        final streamIds = List.generate(5, (_) => transport.createStream());

        // Assert
        for (final streamId in streamIds) {
          expect(
            streamId % 2,
            equals(1),
            reason: 'a client-side stream id must be odd',
          );
        }

        // Cleanup
        result.kill();
      });
    });

    group('sendMessage and sendMetadata', () {
      test('sends messages into the isolate', () async {
        // Arrange
        final result = await RpcIsolateTransport.spawn(
          entrypoint: _testEchoServer,
          customParams: {},
          isolateId: 'message-test',
        );

        final transport = result.transport;
        final streamId = transport.createStream();
        final receivedMessages = <RpcTransportMessage>[];

        transport.incomingMessages.listen(receivedMessages.add);

        // Act
        final testData = Uint8List.fromList('Hello Isolate'.codeUnits);
        await transport.sendMessage(streamId, testData);

        // Let the isolate handle it.
        await Future<void>.delayed(Duration(milliseconds: 200));

        // Assert
        expect(receivedMessages.length, greaterThan(0));
        final echoMessage = receivedMessages.firstWhere(
          (msg) => !msg.isMetadataOnly && msg.payload != null,
          orElse: () => throw StateError('Echo message not found'),
        );

        final receivedText = String.fromCharCodes(echoMessage.payload!);
        expect(receivedText, contains('Hello Isolate'));

        // Cleanup
        result.kill();
      });

      test('sends metadata into the isolate', () async {
        // Arrange
        final result = await RpcIsolateTransport.spawn(
          entrypoint: _testFullCycleServer,
          customParams: {},
          isolateId: 'metadata-test',
        );

        final transport = result.transport;
        final streamId = transport.createStream();
        final receivedMessages = <RpcTransportMessage>[];

        transport.incomingMessages.listen(receivedMessages.add);

        // Act
        final metadata = RpcMetadata.forClientRequest(
          'TestService',
          'TestMethod',
        );
        await transport.sendMetadata(streamId, metadata);

        // Let the isolate handle it.
        await Future<void>.delayed(Duration(milliseconds: 200));

        // Assert
        expect(receivedMessages.length, greaterThan(0));
        final metadataMessage = receivedMessages.firstWhere(
          (msg) => msg.isMetadataOnly,
          orElse: () => throw StateError('Metadata message not found'),
        );

        expect(metadataMessage.metadata, isNotNull);

        // Cleanup
        result.kill();
      });

      test('honors the end-stream flag', () async {
        // Arrange
        final result = await RpcIsolateTransport.spawn(
          entrypoint: _testFullCycleServer,
          customParams: {},
          isolateId: 'endstream-test',
        );

        final transport = result.transport;
        final streamId = transport.createStream();
        final receivedMessages = <RpcTransportMessage>[];

        transport.incomingMessages.listen(receivedMessages.add);

        // Act
        await transport.sendMessage(
          streamId,
          Uint8List.fromList('test'.codeUnits),
          endStream: true,
        );

        // Let the isolate handle it.
        await Future<void>.delayed(Duration(milliseconds: 200));

        // Assert
        expect(receivedMessages.length, greaterThan(0));
        final endStreamMessage = receivedMessages.firstWhere(
          (msg) => msg.isEndOfStream,
          orElse: () => throw StateError('End stream message not found'),
        );

        expect(endStreamMessage.isEndOfStream, isTrue);

        // Cleanup
        result.kill();
      });
    });

    group('finishSending', () {
      test('sends an end-stream message', () async {
        // Arrange
        final result = await RpcIsolateTransport.spawn(
          entrypoint: _testFinishServer,
          customParams: {},
          isolateId: 'finish-test',
        );

        final transport = result.transport;
        final streamId = transport.createStream();
        final receivedMessages = <RpcTransportMessage>[];

        transport.incomingMessages.listen(receivedMessages.add);

        // Act
        await transport.finishSending(streamId);

        // Let the isolate handle it.
        await Future<void>.delayed(Duration(milliseconds: 200));

        // Assert
        expect(receivedMessages.length, greaterThan(0));
        final finishMessage = receivedMessages.firstWhere(
          (msg) => msg.isEndOfStream && msg.streamId == streamId,
          orElse: () => throw StateError('Finish message not found'),
        );

        expect(finishMessage.isEndOfStream, isTrue);
        expect(finishMessage.streamId, equals(streamId));

        // Cleanup
        result.kill();
      });

      test('a second call sends nothing', () async {
        // Arrange
        final result = await RpcIsolateTransport.spawn(
          entrypoint: _testFinishServer,
          customParams: {},
          isolateId: 'repeat-finish-test',
        );

        final transport = result.transport;
        final streamId = transport.createStream();
        final receivedMessages = <RpcTransportMessage>[];

        transport.incomingMessages.listen(receivedMessages.add);

        // Act
        await transport.finishSending(streamId);
        await transport.finishSending(streamId); // The second call.

        // Let the isolate handle it.
        await Future<void>.delayed(Duration(milliseconds: 200));

        // Assert
        final finishMessages = receivedMessages
            .where((msg) => msg.isEndOfStream && msg.streamId == streamId)
            .toList();

        expect(finishMessages.length, equals(1)); // One message, not two.

        // Cleanup
        result.kill();
      });
    });

    group('getMessagesForStream', () {
      test('filters messages by stream id', () async {
        // Arrange
        final result = await RpcIsolateTransport.spawn(
          entrypoint: _testMultiStreamServer,
          customParams: {},
          isolateId: 'filter-test',
        );

        final transport = result.transport;
        final streamId1 = transport.createStream();
        final streamId2 = transport.createStream();

        final stream1Messages = <RpcTransportMessage>[];
        final stream2Messages = <RpcTransportMessage>[];

        transport.getMessagesForStream(streamId1).listen(stream1Messages.add);
        transport.getMessagesForStream(streamId2).listen(stream2Messages.add);

        // Act
        await transport.sendMessage(
          streamId1,
          Uint8List.fromList('message1'.codeUnits),
        );
        await transport.sendMessage(
          streamId2,
          Uint8List.fromList('message2'.codeUnits),
        );
        await transport.sendMessage(
          streamId1,
          Uint8List.fromList('message3'.codeUnits),
        );

        // Let the isolate handle it.
        await Future<void>.delayed(Duration(milliseconds: 200));

        // Assert
        expect(stream1Messages.length, greaterThan(0));
        expect(stream2Messages.length, greaterThan(0));

        // Every message must land on the stream it was sent on.
        for (final msg in stream1Messages) {
          expect(msg.streamId, equals(streamId1));
        }
        for (final msg in stream2Messages) {
          expect(msg.streamId, equals(streamId2));
        }

        // Cleanup
        result.kill();
      });
    });

    group('close', () {
      test('closes the transport cleanly', () async {
        // Arrange
        final result = await RpcIsolateTransport.spawn(
          entrypoint: _testEchoServer,
          customParams: {},
          isolateId: 'close-test',
        );

        final transport = result.transport;

        // Act
        await transport.close();

        // Assert
        // Nothing may be sent once the transport is closed.
        final streamId = transport.createStream();

        // A send after close is REFUSED: returning quietly told the caller the
        // message had gone out when it never reached the wire.
        await expectLater(
          transport.sendMessage(streamId, Uint8List.fromList('test'.codeUnits)),
          throwsA(isA<RpcStatusException>()),
        );

        // Cleanup
        result.kill();
      });
    });

    group('integration', () {
      test('a full round of message exchange', () async {
        // Arrange
        final result = await RpcIsolateTransport.spawn(
          entrypoint: _testFullCycleServer,
          customParams: {'responseCount': 3},
          isolateId: 'full-cycle-test',
        );

        final transport = result.transport;
        final streamId = transport.createStream();
        final receivedMessages = <RpcTransportMessage>[];

        transport.getMessagesForStream(streamId).listen(receivedMessages.add);

        // Act
        // Metadata first.
        final metadata = RpcMetadata.forClientRequest(
          'TestService',
          'FullCycle',
        );
        await transport.sendMetadata(streamId, metadata);

        // Then the message.
        await transport.sendMessage(
          streamId,
          Uint8List.fromList('test request'.codeUnits),
        );

        // Then half-close.
        await transport.finishSending(streamId);

        // Let the isolate handle it.
        await Future<void>.delayed(Duration(milliseconds: 200));

        // Assert
        expect(receivedMessages.length, greaterThan(0));

        // Both metadata and data must have come back.
        final metadataMessages = receivedMessages
            .where((msg) => msg.isMetadataOnly)
            .toList();
        final dataMessages = receivedMessages
            .where((msg) => !msg.isMetadataOnly && msg.payload != null)
            .toList();

        expect(metadataMessages.length, greaterThan(0));
        expect(dataMessages.length, greaterThan(0));

        // Cleanup
        result.kill();
      });

      test('an error raised inside the isolate comes back', () async {
        // Arrange
        final result = await RpcIsolateTransport.spawn(
          entrypoint: _testErrorServer,
          customParams: {},
          isolateId: 'error-test',
        );

        final transport = result.transport;
        final streamId = transport.createStream();
        final receivedMessages = <RpcTransportMessage>[];

        transport.getMessagesForStream(streamId).listen(receivedMessages.add);

        // Act
        await transport.sendMessage(
          streamId,
          Uint8List.fromList('trigger error'.codeUnits),
        );

        // Let the isolate handle it.
        await Future<void>.delayed(Duration(milliseconds: 200));

        // Assert
        // We expect an error message.
        expect(receivedMessages.length, greaterThan(0));

        // Cleanup
        result.kill();
      });
    });

    group('zero-copy via sendDirectObject', () {
      test('carries a complex object with no serialization', () async {
        // Arrange
        final result = await RpcIsolateTransport.spawn(
          entrypoint: _testZeroCopyServer,
          customParams: {},
          isolateId: 'zero-copy-test',
        );

        final transport = result.transport;
        final streamId = transport.createStream();
        final receivedMessages = <RpcTransportMessage>[];

        transport.incomingMessages.listen(receivedMessages.add);

        // Act: send a complex object directly.
        final complexObject = TestComplexObject(
          id: 42,
          name: 'Test User',
          metadata: {
            'roles': ['admin', 'user'],
            'permissions': {'read': true, 'write': false},
            'settings': {'theme': 'dark', 'language': 'ru'},
          },
          tags: ['important', 'test'],
          createdAt: DateTime(2024, 1, 15),
          isActive: true,
        );

        await transport.sendDirectObject(streamId, complexObject);

        // Let the isolate handle it.
        await Future<void>.delayed(Duration(milliseconds: 300));

        // Assert
        expect(receivedMessages.length, greaterThan(0));

        // Find the zero-copy response.
        final directMessage = receivedMessages.firstWhere(
          (msg) => msg.isDirect && msg.directPayload != null,
          orElse: () => throw StateError('Zero-copy response not found'),
        );

        expect(directMessage.directPayload, isA<TestComplexObject>());
        final responseObject = directMessage.directPayload as TestComplexObject;

        // The object crossed intact and the server's edits came back with it.
        expect(responseObject.id, equals(42));
        expect(responseObject.name, equals('Test User [PROCESSED]'));
        expect(
          responseObject.metadata['roles'],
          equals(['admin', 'user', 'zero-copy']),
        );
        expect(responseObject.tags.length, equals(3)); // 'processed' was added.
        expect(responseObject.isActive, equals(true));

        // Cleanup
        result.kill();
      });

      test('carries primitives and collections zero-copy', () async {
        // Arrange
        final result = await RpcIsolateTransport.spawn(
          entrypoint: _testPrimitivesZeroCopyServer,
          customParams: {},
          isolateId: 'primitives-zero-copy',
        );

        final transport = result.transport;
        // transport.createStream();
        final receivedMessages = <RpcTransportMessage>[];

        transport.incomingMessages.listen(receivedMessages.add);

        // Act: send a range of payload types.
        final testCases = [
          {
            'numbers': [1, 2, 3, 4, 5],
          },
          'simple string',
          42,
          true,
          [
            1,
            'mixed',
            true,
            {'nested': 'value'},
          ],
        ];

        for (int i = 0; i < testCases.length; i++) {
          final newStreamId = transport.createStream();
          await transport.sendDirectObject(newStreamId, testCases[i]);
        }

        // Let the isolate handle all of them.
        await Future<void>.delayed(Duration(milliseconds: 400));

        // Assert
        expect(receivedMessages.length, greaterThanOrEqualTo(testCases.length));

        final directResponses = receivedMessages
            .where((msg) => msg.isDirect && msg.directPayload != null)
            .toList();

        expect(directResponses.length, equals(testCases.length));

        // Check every response.
        for (int i = 0; i < directResponses.length; i++) {
          final response = directResponses[i].directPayload;
          expect(response.toString(), contains('ECHO:'));
        }

        // Cleanup
        result.kill();
      });

      test('times zero-copy against serialization', () async {
        // Arrange
        final result = await RpcIsolateTransport.spawn(
          entrypoint: _testPerformanceServer,
          customParams: {},
          isolateId: 'performance-test',
        );

        final transport = result.transport;
        final largeObject = TestLargeObject.generate(5000);

        // Act & Assert - Zero-copy
        final stopwatchZeroCopy = Stopwatch()..start();

        for (int i = 0; i < 50; i++) {
          final streamId = transport.createStream();
          await transport.sendDirectObject(streamId, largeObject);
        }

        stopwatchZeroCopy.stop();
        final zeroCopyTime = stopwatchZeroCopy.elapsedMicroseconds;

        // Act & Assert - ordinary serialization (JSON)
        final stopwatchSerialized = Stopwatch()..start();

        for (int i = 0; i < 50; i++) {
          final streamId = transport.createStream();
          // Stand in for a full serialization to JSON.
          final jsonString = largeObject.data.toString();
          final serialized = Uint8List.fromList(jsonString.codeUnits);
          await transport.sendMessage(streamId, serialized);
        }

        stopwatchSerialized.stop();
        final serializedTime = stopwatchSerialized.elapsedMicroseconds;

        print('zero-copy: ${zeroCopyTime}us');
        print('serialization: ${serializedTime}us');

        if (zeroCopyTime < serializedTime) {
          print(
            'zero-copy is '
            '${(serializedTime / zeroCopyTime).toStringAsFixed(2)}x faster',
          );
        } else {
          print(
            'at this size serialization is '
            '${(zeroCopyTime / serializedTime).toStringAsFixed(2)}x faster; '
            'zero-copy pays off on very large or deeply nested objects',
          );
        }

        // Zero-copy's advantage is skipping serialization entirely, which is
        // size-dependent, so the assertion is only that both paths work.
        expect(zeroCopyTime, greaterThan(0));
        expect(serializedTime, greaterThan(0));

        // Cleanup
        result.kill();
      });

      test('reports an error raised on the zero-copy path', () async {
        // Arrange
        final result = await RpcIsolateTransport.spawn(
          entrypoint: _testZeroCopyErrorServer,
          customParams: {},
          isolateId: 'zero-copy-error-test',
        );

        final transport = result.transport;
        final streamId = transport.createStream();
        final receivedMessages = <RpcTransportMessage>[];

        transport.incomingMessages.listen(receivedMessages.add);

        // Act: send the object the server is written to fail on.
        final errorTrigger = TestComplexObject(
          id: -1, // The id the server treats as the error trigger.
          name: 'Error Trigger',
          metadata: {},
          tags: [],
          createdAt: DateTime.now(),
          isActive: false,
        );

        await transport.sendDirectObject(streamId, errorTrigger);

        // Let the isolate handle it.
        await Future<void>.delayed(Duration(milliseconds: 200));

        // Assert
        expect(receivedMessages.length, greaterThan(0));

        // The error arrives in metadata, the way gRPC carries one.
        final errorMessage = receivedMessages.firstWhere(
          (msg) => msg.metadata != null && msg.isEndOfStream,
          orElse: () => throw StateError('Error response not found'),
        );

        expect(errorMessage.metadata, isNotNull);

        // Cleanup
        result.kill();
      });
    });

    group('releaseStreamId', () {
      test('releases an active stream id', () async {
        // Arrange
        final result = await RpcIsolateTransport.spawn(
          entrypoint: _testEchoServer,
          customParams: {},
          isolateId: 'release-test',
        );

        final transport = result.transport;
        final streamId = transport.createStream();

        // Act: first make sure the stream exists.
        expect(streamId, greaterThan(0));

        // Then release it.
        final released = transport.releaseStreamId(streamId);

        // Assert
        expect(
          released,
          isTrue,
          reason: 'releasing an active stream must return true',
        );

        // Cleanup
        result.kill();
      });

      test('returns false for a stream id that never existed', () async {
        // Arrange
        final result = await RpcIsolateTransport.spawn(
          entrypoint: _testEchoServer,
          customParams: {},
          isolateId: 'release-nonexistent-test',
        );

        final transport = result.transport;

        // Act: try to release a stream id that was never issued.
        final released = transport.releaseStreamId(99999);

        // Assert
        expect(
          released,
          isFalse,
          reason: 'releasing an unknown stream must return false',
        );

        // Cleanup
        result.kill();
      });

      test('returns false for an already-released stream id', () async {
        // Arrange
        final result = await RpcIsolateTransport.spawn(
          entrypoint: _testEchoServer,
          customParams: {},
          isolateId: 'release-twice-test',
        );

        final transport = result.transport;
        final streamId = transport.createStream();

        // Act: release it twice.
        final firstRelease = transport.releaseStreamId(streamId);
        final secondRelease = transport.releaseStreamId(streamId);

        // Assert
        expect(firstRelease, isTrue, reason: 'the first release must succeed');
        expect(
          secondRelease,
          isFalse,
          reason: 'a second release must return false',
        );

        // Cleanup
        result.kill();
      });

      test('returns false once the transport is closed', () async {
        // Arrange
        final result = await RpcIsolateTransport.spawn(
          entrypoint: _testEchoServer,
          customParams: {},
          isolateId: 'release-closed-test',
        );

        final transport = result.transport;
        final streamId = transport.createStream();

        // Act: close the transport, then try to release the stream.
        await transport.close();
        final released = transport.releaseStreamId(streamId);

        // Assert
        expect(
          released,
          isFalse,
          reason: 'a closed transport must return false',
        );
        expect(transport.isClosed, isTrue);

        // Cleanup
        result.kill();
      });

      test('releases several stream ids', () async {
        // Arrange
        final result = await RpcIsolateTransport.spawn(
          entrypoint: _testEchoServer,
          customParams: {},
          isolateId: 'release-multiple-test',
        );

        final transport = result.transport;
        final streamIds = List.generate(5, (_) => transport.createStream());

        // Act: release every stream.
        final results = streamIds.map(transport.releaseStreamId).toList();

        // Assert
        expect(
          results.every((result) => result == true),
          isTrue,
          reason: 'every stream must be released successfully',
        );

        // A second release must return false.
        final secondResults = streamIds.map(transport.releaseStreamId).toList();
        expect(
          secondResults.every((result) => result == false),
          isTrue,
          reason: 'a second release must return false',
        );

        // Cleanup
        result.kill();
      });

      test('sending on a released stream id does not throw', () async {
        // Arrange
        final result = await RpcIsolateTransport.spawn(
          entrypoint: _testEchoServer,
          customParams: {},
          isolateId: 'release-after-message-test',
        );

        final transport = result.transport;
        final streamId = transport.createStream();
        final receivedMessages = <RpcTransportMessage>[];

        transport.incomingMessages.listen(receivedMessages.add);

        // Act: send a message.
        final testData = Uint8List.fromList('Test message'.codeUnits);
        await transport.sendMessage(streamId, testData);

        // Wait for the answer.
        await Future<void>.delayed(Duration(milliseconds: 100));

        // Release the stream.
        final released = transport.releaseStreamId(streamId);

        // Sending once more must not throw.
        await transport.sendMessage(streamId, testData);

        // Assert
        expect(released, isTrue);
        expect(receivedMessages.length, greaterThan(0));

        // Cleanup
        result.kill();
      });
    });
  });
}

/// A plain echo server.
@pragma('vm:entry-point')
void _testEchoServer(IRpcTransport transport, Map<String, dynamic> params) {
  transport.incomingMessages.listen((message) async {
    if (!message.isMetadataOnly && message.payload != null) {
      // Echo the message back.
      final echoData = Uint8List.fromList(
        'Echo: ${String.fromCharCodes(message.payload!)}'.codeUnits,
      );
      await transport.sendMessage(message.streamId, echoData);
    }
  });
}

/// A server that echoes with a prefix taken from its custom params.
@pragma('vm:entry-point')
void _testParameterServer(
  IRpcTransport transport,
  Map<String, dynamic> params,
) {
  final responsePrefix = params['responsePrefix'] as String? ?? '[DEFAULT]: ';

  transport.incomingMessages.listen((message) async {
    if (!message.isMetadataOnly && message.payload != null) {
      final originalText = String.fromCharCodes(message.payload!);
      final responseText = '$responsePrefix$originalText';
      final responseData = Uint8List.fromList(responseText.codeUnits);

      await transport.sendMessage(message.streamId, responseData);
    }
  });
}

/// A server that throws on startup.
@pragma('vm:entry-point')
void _faultyServer(IRpcTransport transport, Map<String, dynamic> params) {
  throw Exception('Intentional server error');
}

/// A multi-stream server, for the stream-id filtering test.
@pragma('vm:entry-point')
void _testMultiStreamServer(
  IRpcTransport transport,
  Map<String, dynamic> params,
) {
  transport.incomingMessages.listen((message) async {
    if (!message.isMetadataOnly && message.payload != null) {
      final originalText = String.fromCharCodes(message.payload!);
      final responseText =
          'Response for stream ${message.streamId}: $originalText';
      final responseData = Uint8List.fromList(responseText.codeUnits);

      await transport.sendMessage(message.streamId, responseData);
    }
  });
}

/// A full-cycle server, for the integration tests.
@pragma('vm:entry-point')
void _testFullCycleServer(
  IRpcTransport transport,
  Map<String, dynamic> params,
) {
  final responseCount = params['responseCount'] as int? ?? 1;

  transport.incomingMessages.listen((message) async {
    if (message.isMetadataOnly && !message.isEndOfStream) {
      // Initial metadata.
      final initialMetadata = RpcMetadata.forServerInitialResponse();
      await transport.sendMetadata(message.streamId, initialMetadata);
    } else if (!message.isMetadataOnly && message.payload != null) {
      // Then the responses.
      for (int i = 1; i <= responseCount; i++) {
        final responseText = 'Response $i of $responseCount';
        final responseData = Uint8List.fromList(responseText.codeUnits);
        await transport.sendMessage(message.streamId, responseData);
      }

      // Then the trailer.
      final finalMetadata = RpcMetadata.forTrailer(RpcStatus.ok);
      await transport.sendMetadata(
        message.streamId,
        finalMetadata,
        endStream: true,
      );
    }
  });
}

/// A server that answers every message with an error trailer.
@pragma('vm:entry-point')
void _testErrorServer(IRpcTransport transport, Map<String, dynamic> params) {
  transport.incomingMessages.listen((message) async {
    if (!message.isMetadataOnly && message.payload != null) {
      // Answer with an error.
      final errorMetadata = RpcMetadata.forTrailer(
        RpcStatus.internal,
        message: 'Test error',
      );
      await transport.sendMetadata(
        message.streamId,
        errorMetadata,
        endStream: true,
      );
    }
  });
}

/// A plain server for the finishSending tests.
@pragma('vm:entry-point')
void _testFinishServer(IRpcTransport transport, Map<String, dynamic> params) {
  transport.incomingMessages.listen((message) async {
    // Answer every message, END_STREAM included.
    if (message.isEndOfStream) {
      // Acknowledge the END_STREAM.
      await transport.finishSending(message.streamId);
    } else if (!message.isMetadataOnly && message.payload != null) {
      // Echo an ordinary message.
      final echoData = Uint8List.fromList(
        'Echo: ${String.fromCharCodes(message.payload!)}'.codeUnits,
      );
      await transport.sendMessage(message.streamId, echoData);
    }
  });
}

/// A zero-copy server for complex objects.
@pragma('vm:entry-point')
void _testZeroCopyServer(IRpcTransport transport, Map<String, dynamic> params) {
  transport.incomingMessages.listen((message) async {
    if (message.isDirect && message.directPayload != null) {
      // The object arrives directly, with no deserialization.
      final receivedObject = message.directPayload as TestComplexObject;

      // Edit it, so the test can see the edits come back.
      final modifiedObject = TestComplexObject(
        id: receivedObject.id,
        name: '${receivedObject.name} [PROCESSED]',
        metadata: {
          ...receivedObject.metadata,
          'roles': [...(receivedObject.metadata['roles'] as List), 'zero-copy'],
        },
        tags: [...receivedObject.tags, 'processed'],
        createdAt: receivedObject.createdAt,
        isActive: receivedObject.isActive,
      );

      // Send it back the same way.
      await transport.sendDirectObject(
        message.streamId,
        modifiedObject,
        endStream: true,
      );
    }
  });
}

/// A zero-copy server for primitives and collections.
@pragma('vm:entry-point')
void _testPrimitivesZeroCopyServer(
  IRpcTransport transport,
  Map<String, dynamic> params,
) {
  transport.incomingMessages.listen((message) async {
    if (message.isDirect && message.directPayload != null) {
      // Take whatever arrives and echo it.
      final received = message.directPayload;
      final echo = 'ECHO: $received';

      await transport.sendDirectObject(message.streamId, echo, endStream: true);
    }
  });
}

/// A server for the timing comparison.
@pragma('vm:entry-point')
void _testPerformanceServer(
  IRpcTransport transport,
  Map<String, dynamic> params,
) {
  transport.incomingMessages.listen((message) async {
    if (message.isDirect && message.directPayload != null) {
      // Acknowledge and nothing more.
      await transport.sendDirectObject(message.streamId, 'OK', endStream: true);
    } else if (message.payload != null) {
      // Same for serialized data.
      final response = Uint8List.fromList('OK'.codeUnits);
      await transport.sendMessage(message.streamId, response, endStream: true);
    }
  });
}

/// A zero-copy server that fails on one particular payload.
@pragma('vm:entry-point')
void _testZeroCopyErrorServer(
  IRpcTransport transport,
  Map<String, dynamic> params,
) {
  transport.incomingMessages.listen((message) async {
    if (message.isDirect && message.directPayload != null) {
      final receivedObject = message.directPayload as TestComplexObject;

      // An id of -1 is the error trigger.
      if (receivedObject.id == -1) {
        // The error goes back in metadata, the way gRPC carries one.
        final errorMetadata = RpcMetadata.forTrailer(
          RpcStatus.invalidArgument,
          message: 'Invalid object ID: ${receivedObject.id}',
        );
        await transport.sendMetadata(
          message.streamId,
          errorMetadata,
          endStream: true,
        );
      } else {
        // The ordinary path.
        await transport.sendDirectObject(
          message.streamId,
          'Success',
          endStream: true,
        );
      }
    }
  });
}
