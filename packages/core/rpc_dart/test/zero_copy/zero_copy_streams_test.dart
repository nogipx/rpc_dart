// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';
import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

class TestRequest implements IRpcSerializable {
  final String message;

  TestRequest(this.message);

  @override
  Map<String, dynamic> toJson() => {'message': message};

  static TestRequest fromJson(Map<String, dynamic> json) =>
      TestRequest(json['message'] as String);

  @override
  String toString() => 'TestRequest($message)';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TestRequest && message == other.message;

  @override
  int get hashCode => message.hashCode;
}

class TestResponse implements IRpcSerializable {
  final String result;

  TestResponse(this.result);

  @override
  Map<String, dynamic> toJson() => {'result': result};

  static TestResponse fromJson(Map<String, dynamic> json) =>
      TestResponse(json['result'] as String);

  @override
  String toString() => 'TestResponse($result)';

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is TestResponse && result == other.result;

  @override
  int get hashCode => result.hashCode;
}

final class StreamingTestService extends RpcResponderContract {
  StreamingTestService() : super('StreamingTestService');

  @override
  void setup() {
    // Server stream: one request, a stream of answers.
    addServerStreamMethod<TestRequest, TestResponse>(
      methodName: 'GetNumbers',
      handler: (request, {context}) async* {
        final count = int.tryParse(request.message) ?? 3;
        for (int i = 1; i <= count; i++) {
          yield TestResponse('Number $i for: ${request.message}');
          await Future<void>.delayed(Duration(milliseconds: 1));
        }
      },
      // No codecs passed -> zero-copy mode, automatically.
      description: 'Zero-copy server stream that generates numbers',
    );

    // Client stream: a stream of requests, one answer.
    addClientStreamMethod<TestRequest, TestResponse>(
      methodName: 'ProcessItems',
      handler: (requests, {context}) async {
        final items = <String>[];
        await for (final request in requests) {
          items.add(request.message);
        }
        return TestResponse(
          'Processed ${items.length} items: ${items.join(", ")}',
        );
      },
      // No codecs passed -> zero-copy mode, automatically.
      description: 'Zero-copy client stream that processes items',
    );

    // Bidirectional: a stream each way.
    addBidirectionalMethod<TestRequest, TestResponse>(
      methodName: 'Chat',
      handler: (requests, {context}) async* {
        await for (final request in requests) {
          if (request.message.startsWith('ping')) {
            yield TestResponse('pong');
          } else {
            yield TestResponse('echo: ${request.message}');
          }
          await Future<void>.delayed(Duration(milliseconds: 1));
        }
      },
      // No codecs passed -> zero-copy mode, automatically.
      description: 'Zero-copy bidirectional stream for a chat',
    );
  }
}

void main() {
  group('Zero-copy streams', () {
    late RpcResponderEndpoint serverEndpoint;
    late RpcCallerEndpoint clientEndpoint;
    late StreamingTestService testService;
    late IRpcTransport clientTransport;
    late IRpcTransport serverTransport;
    final sentMessages = <RpcTransportMessage>[];

    setUp(() async {
      final pair = RpcInMemoryTransport.pair();
      clientTransport = pair.$1;
      serverTransport = pair.$2;

      serverEndpoint = RpcResponderEndpoint(transport: serverTransport);
      testService = StreamingTestService();
      serverEndpoint.registerServiceContract(testService);
      serverEndpoint.start();

      clientEndpoint = RpcCallerEndpoint(transport: clientTransport);

      // Watch every message.
      sentMessages.clear();
      serverTransport.incomingMessages.listen((message) {
        sentMessages.add(message);

        if (message.isSerialized && message.payload != null) {
          print('\nSERIALIZED');
          print('   size: ${message.payload!.length} bytes');
          print('   Stream ID: ${message.streamId}');
          print('   Type: ${message.runtimeType}');
        } else if (message.isDirect && message.directPayload != null) {
          print('\nZERO-COPY');
          print('   object: ${message.directPayload.runtimeType}');
          print('   Stream ID: ${message.streamId}');
          print('   Data: ${message.directPayload}');
        }
      });
    });

    tearDown(() async {
      await clientEndpoint.close();
      await serverEndpoint.close();
    });

    test('server stream, zero-copy', () async {
      print('\n=== SERVER STREAM ZERO-COPY TEST ===');

      final request = TestRequest('3');

      // A server-stream call with NO CODECS, so zero-copy applies.
      final responses = <TestResponse>[];
      await for (final response
          in clientEndpoint.serverStream<TestRequest, TestResponse>(
            serviceName: 'StreamingTestService',
            methodName: 'GetNumbers',
            // No codecs passed -> zero-copy mode, automatically.
            request: request,
          )) {
        responses.add(response);
        print('answer: ${response.result}');
      }

      // Let every message land.
      await Future<void>.delayed(Duration(milliseconds: 1));

      print('\nwhat went over the wire:');
      print('   messages: ${sentMessages.length}');

      final serializedMessages = sentMessages
          .where((m) => m.isSerialized)
          .length;
      final directMessages = sentMessages.where((m) => m.isDirect).length;
      final metadataMessages = sentMessages
          .where((m) => m.metadata != null && !m.isSerialized && !m.isDirect)
          .length;

      print('   serialized: $serializedMessages');
      print('   zero-copy: $directMessages');
      print('   metadata only: $metadataMessages');

      expect(responses.length, equals(3));
      expect(responses[0].result, equals('Number 1 for: 3'));
      expect(responses[1].result, equals('Number 2 for: 3'));
      expect(responses[2].result, equals('Number 3 for: 3'));

      expect(
        directMessages,
        greaterThan(0),
        reason: 'the messages must go zero-copy',
      );
      print(
        directMessages > 0
            ? '\nserver stream zero-copy works'
            : '\nzero-copy did NOT happen',
      );
    });

    test('client stream, zero-copy', () async {
      print('\n=== CLIENT STREAM ZERO-COPY TEST ===');

      sentMessages.clear();

      final requestStream = Stream.fromIterable([
        TestRequest('item1'),
        TestRequest('item2'),
        TestRequest('item3'),
      ]);

      final response = await clientEndpoint
          .clientStream<TestRequest, TestResponse>(
            serviceName: 'StreamingTestService',
            methodName: 'ProcessItems',
            // No codecs passed -> zero-copy mode, automatically.
          )(requestStream);

      print('final answer: ${response.result}');

      // Let every message land.
      await Future<void>.delayed(Duration(milliseconds: 1));

      print('\nwhat went over the wire:');
      print('   messages: ${sentMessages.length}');

      final serializedMessages = sentMessages
          .where((m) => m.isSerialized)
          .length;
      final directMessages = sentMessages.where((m) => m.isDirect).length;

      print('   serialized: $serializedMessages');
      print('   zero-copy: $directMessages');

      expect(response.result, equals('Processed 3 items: item1, item2, item3'));

      expect(
        directMessages,
        greaterThan(0),
        reason: 'the messages must go zero-copy',
      );
      print(
        directMessages > 0
            ? '\nclient stream zero-copy works'
            : '\nzero-copy did NOT happen',
      );
    });

    test('bidirectional stream, zero-copy', () async {
      print('\n=== BIDIRECTIONAL STREAM ZERO-COPY TEST ===');

      sentMessages.clear();

      final requestController = StreamController<TestRequest>();
      final responses = <TestResponse>[];

      final responseStream = clientEndpoint
          .bidirectionalStream<TestRequest, TestResponse>(
            serviceName: 'StreamingTestService',
            methodName: 'Chat',
            // No codecs passed -> zero-copy mode, automatically.
            requests: requestController.stream,
          );

      final subscription = responseStream.listen((response) {
        responses.add(response);
        print('answer: ${response.result}');
      });

      // A few requests.
      requestController.add(TestRequest('ping 1'));
      await Future<void>.delayed(Duration(milliseconds: 1));

      requestController.add(TestRequest('hello world'));
      await Future<void>.delayed(Duration(milliseconds: 1));

      requestController.add(TestRequest('ping 2'));
      await Future<void>.delayed(Duration(milliseconds: 1));

      await requestController.close();

      // Wait on the answers rather than on a fixed sleep: dart2js schedules
      // more coarsely, so poll for all three with a deadline.
      final deadline = DateTime.now().add(Duration(seconds: 5));
      while (responses.length < 3 && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(Duration(milliseconds: 5));
      }

      print('\nwhat went over the wire:');
      print('   messages: ${sentMessages.length}');

      final serializedMessages = sentMessages
          .where((m) => m.isSerialized)
          .length;
      final directMessages = sentMessages.where((m) => m.isDirect).length;

      print('   serialized: $serializedMessages');
      print('   zero-copy: $directMessages');

      expect(responses.length, greaterThanOrEqualTo(3));
      expect(responses.any((r) => r.result == 'pong'), isTrue);
      expect(responses.any((r) => r.result == 'echo: hello world'), isTrue);

      expect(
        directMessages,
        greaterThan(0),
        reason: 'the messages must go zero-copy',
      );
      print(
        directMessages > 0
            ? '\nbidirectional stream zero-copy works'
            : '\nzero-copy did NOT happen',
      );

      await subscription.cancel();
    });

    test('zero-copy against serialization', () async {
      print('\n=== TIMING COMPARISON ===');

      final largeRequest = TestRequest(
        'big data with lots of text that would take time to serialize and deserialize if we were not using zero-copy optimization for inmemory transport which allows us to pass objects by reference',
      );

      sentMessages.clear();
      final stopwatch = Stopwatch()..start();

      // A server stream over a large payload, with NO CODECS.
      final responses = <TestResponse>[];
      await for (final response
          in clientEndpoint.serverStream<TestRequest, TestResponse>(
            serviceName: 'StreamingTestService',
            methodName: 'GetNumbers',
            // No codecs passed -> zero-copy mode, automatically.
            request: largeRequest,
          )) {
        responses.add(response);
      }

      stopwatch.stop();

      print('elapsed: ${stopwatch.elapsedMicroseconds}us');

      final serializedMessages = sentMessages
          .where((m) => m.isSerialized)
          .length;
      final directMessages = sentMessages.where((m) => m.isDirect).length;

      print('results:');
      print('   serialized messages: $serializedMessages');
      print('   zero-copy messages: $directMessages');
      print(
        '   serialization avoided: '
        '${directMessages > serializedMessages ? 'yes' : 'no'}',
      );

      expect(responses.length, equals(3));
      expect(directMessages, greaterThan(0));

      if (directMessages > serializedMessages) {
        print('\nzero-copy applies to streams too');
        print('objects cross by reference, at no marshalling cost');
      }
    });
  });
}
