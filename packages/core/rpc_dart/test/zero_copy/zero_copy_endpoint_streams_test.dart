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

final class ZeroCopyTestService extends RpcResponderContract {
  ZeroCopyTestService() : super('ZeroCopyTestService');

  @override
  void setup() {
    // Server stream, true zero-copy: no codecs.
    addServerStreamMethod<TestRequest, TestResponse>(
      methodName: 'GetNumbers',
      handler: (request, {context}) async* {
        print('SERVER HANDLER received: ${request.message}');
        final count = int.tryParse(request.message) ?? 3;
        for (int i = 1; i <= count; i++) {
          yield TestResponse('Number $i for: ${request.message}');
          await Future<void>.delayed(Duration(milliseconds: 1));
        }
        print('SERVER HANDLER done');
      },
      // No codecs passed -> zero-copy mode, automatically.
    );

    // Client stream, true zero-copy: no codecs.
    addClientStreamMethod<TestRequest, TestResponse>(
      methodName: 'ProcessItems',
      handler: (requests, {context}) async {
        print('CLIENT HANDLER started');
        final items = <String>[];
        await for (final request in requests) {
          print('CLIENT HANDLER received: ${request.message}');
          items.add(request.message);
        }
        final response = TestResponse(
          'Processed ${items.length} items: ${items.join(", ")}',
        );
        print('CLIENT HANDLER done: ${response.result}');
        return response;
      },
      // No codecs passed -> zero-copy mode, automatically.
    );

    // Bidirectional stream, true zero-copy: no codecs.
    addBidirectionalMethod<TestRequest, TestResponse>(
      methodName: 'Chat',
      handler: (requests, {context}) async* {
        print('BIDIRECTIONAL HANDLER started');
        await for (final request in requests) {
          print('BIDIRECTIONAL HANDLER received: ${request.message}');
          if (request.message.startsWith('ping')) {
            yield TestResponse('pong');
          } else {
            yield TestResponse('echo: ${request.message}');
          }
          await Future<void>.delayed(Duration(milliseconds: 1));
        }
        print('BIDIRECTIONAL HANDLER done');
      },
      // No codecs passed -> zero-copy mode, automatically.
    );
  }
}

void main() {
  group('Zero-Copy Endpoint Streams Tests', () {
    late RpcResponderEndpoint serverEndpoint;
    late RpcCallerEndpoint clientEndpoint;
    late ZeroCopyTestService testService;
    late IRpcTransport clientTransport;
    late IRpcTransport serverTransport;

    setUp(() async {
      final pair = RpcInMemoryTransport.pair();
      clientTransport = pair.$1;
      serverTransport = pair.$2;

      serverEndpoint = RpcResponderEndpoint(transport: serverTransport);
      testService = ZeroCopyTestService();
      serverEndpoint.registerServiceContract(testService);
      serverEndpoint.start();

      clientEndpoint = RpcCallerEndpoint(transport: clientTransport);
    });

    tearDown(() async {
      await clientEndpoint.close();
      await serverEndpoint.close();
    });

    test('server stream through the endpoint, zero-copy', () async {
      print('\n=== SERVER STREAM THROUGH THE ENDPOINT ===');

      final sentMessages = <RpcTransportMessage>[];
      serverTransport.incomingMessages.listen((message) {
        sentMessages.add(message);
        if (message.isDirect) {
          print('zero-copy request: ${message.directPayload}');
        }
      });

      clientTransport.incomingMessages.listen((message) {
        if (message.isDirect) {
          print('zero-copy response: ${message.directPayload}');
        }
      });

      final request = TestRequest('3');
      final responses = <TestResponse>[];

      print('calling serverStream through the endpoint...');

      try {
        await for (final response
            in clientEndpoint
                .serverStream<TestRequest, TestResponse>(
                  serviceName: 'ZeroCopyTestService',
                  methodName: 'GetNumbers',
                  request: request,
                )
                .timeout(Duration(seconds: 5))) {
          responses.add(response);
          print('answer: ${response.result}');
        }
      } catch (e) {
        print('error: $e');
      }

      await Future<void>.delayed(Duration(milliseconds: 1));

      print('\nwhat went over the wire:');
      print('   answers: ${responses.length}');
      print('   messages: ${sentMessages.length}');

      final directCount = sentMessages.where((m) => m.isDirect).length;
      final serializedCount = sentMessages.where((m) => m.isSerialized).length;

      print('   zero-copy: $directCount');
      print('   serialized: $serializedCount');

      expect(responses.length, equals(3));
      expect(
        directCount,
        greaterThan(0),
        reason: 'the messages must go zero-copy',
      );

      if (directCount > serializedCount) {
        print('\nzero-copy works through the endpoint');
      }
    });

    test('client stream through the endpoint, zero-copy', () async {
      print('\n=== CLIENT STREAM THROUGH THE ENDPOINT ===');

      final sentMessages = <RpcTransportMessage>[];
      serverTransport.incomingMessages.listen((message) {
        sentMessages.add(message);
        if (message.isDirect) {
          print('zero-copy request: ${message.directPayload}');
        }
      });

      final requests = [
        TestRequest('item1'),
        TestRequest('item2'),
        TestRequest('item3'),
      ];

      print('calling clientStream through the endpoint...');

      try {
        final response = await clientEndpoint
            .clientStream<TestRequest, TestResponse>(
              serviceName: 'ZeroCopyTestService',
              methodName: 'ProcessItems',
            )(Stream.fromIterable(requests))
            .timeout(Duration(seconds: 5));

        print('answer: ${response.result}');

        await Future<void>.delayed(Duration(milliseconds: 1));

        print('\nwhat went over the wire:');
        final directCount = sentMessages.where((m) => m.isDirect).length;
        final serializedCount = sentMessages
            .where((m) => m.isSerialized)
            .length;

        print('   zero-copy: $directCount');
        print('   serialized: $serializedCount');

        expect(response.result, contains('Processed 3 items'));
        expect(
          directCount,
          greaterThan(0),
          reason: 'the messages must go zero-copy',
        );

        if (directCount > serializedCount) {
          print('\nclient stream zero-copy works');
        }
      } catch (e) {
        print('error: $e');
        fail('Client stream failed: $e');
      }
    });

    test('bidirectional stream through the endpoint, zero-copy', () async {
      print('\n=== BIDIRECTIONAL STREAM THROUGH THE ENDPOINT ===');

      final sentMessages = <RpcTransportMessage>[];
      serverTransport.incomingMessages.listen((message) {
        sentMessages.add(message);
        if (message.isDirect) {
          print('zero-copy request: ${message.directPayload}');
        }
      });

      clientTransport.incomingMessages.listen((message) {
        if (message.isDirect) {
          print('zero-copy response: ${message.directPayload}');
        }
      });

      final requestController = StreamController<TestRequest>();
      final responses = <TestResponse>[];

      print('calling bidirectionalStream through the endpoint...');

      try {
        final responseStream = clientEndpoint
            .bidirectionalStream<TestRequest, TestResponse>(
              serviceName: 'ZeroCopyTestService',
              methodName: 'Chat',
              requests: requestController.stream,
            );

        final subscription = responseStream.listen((response) {
          responses.add(response);
          print('answer: ${response.result}');
        });

        // Send the requests.
        requestController.add(TestRequest('ping 1'));
        await Future<void>.delayed(Duration(milliseconds: 1));

        requestController.add(TestRequest('hello'));
        await Future<void>.delayed(Duration(milliseconds: 1));

        await requestController.close();
        await Future<void>.delayed(Duration(milliseconds: 1));

        print('\nwhat went over the wire:');
        final directCount = sentMessages.where((m) => m.isDirect).length;
        final serializedCount = sentMessages
            .where((m) => m.isSerialized)
            .length;

        print('   answers: ${responses.length}');
        print('   zero-copy: $directCount');
        print('   serialized: $serializedCount');

        expect(responses.length, greaterThanOrEqualTo(2));
        expect(
          directCount,
          greaterThan(0),
          reason: 'the messages must go zero-copy',
        );

        if (directCount > serializedCount) {
          print('\nbidirectional stream zero-copy works');
        }

        await subscription.cancel();
      } catch (e) {
        print('error: $e');
        fail('Bidirectional stream failed: $e');
      }
    });
  });
}
