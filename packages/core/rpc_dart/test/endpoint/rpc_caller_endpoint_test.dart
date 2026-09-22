// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

/// The request model.
class TestRequest implements IRpcSerializable {
  final String message;

  TestRequest(this.message);

  factory TestRequest.fromJson(Map<String, dynamic> json) {
    return TestRequest(json['message'] as String);
  }

  @override
  Map<String, dynamic> toJson() {
    return {'message': message};
  }
}

/// The response model.
class TestResponse implements IRpcSerializable {
  final String message;

  TestResponse(this.message);

  factory TestResponse.fromJson(Map<String, dynamic> json) {
    return TestResponse(json['message'] as String);
  }

  @override
  Map<String, dynamic> toJson() {
    return {'message': message};
  }
}

/// The responder contract these tests call into.
final class TestService extends RpcResponderContract {
  final List<String> callLog = [];

  TestService() : super('TestService');

  @override
  void setup() {
    addUnaryMethod<TestRequest, TestResponse>(
      methodName: 'UnaryMethod',
      handler: (request, {context}) async {
        callLog.add('UnaryMethod: ${request.message}');
        return TestResponse('Reply to: ${request.message}');
      },
      requestCodec: RpcCodec<TestRequest>(TestRequest.fromJson),
      responseCodec: RpcCodec<TestResponse>(TestResponse.fromJson),
    );

    addServerStreamMethod<TestRequest, TestResponse>(
      methodName: 'ServerStreamMethod',
      handler: (request, {context}) async* {
        callLog.add('ServerStreamMethod: ${request.message}');
        for (int i = 0; i < 3; i++) {
          yield TestResponse('Reply ${i + 1} to: ${request.message}');
          await Future<void>.delayed(Duration(milliseconds: 1));
        }
      },
      requestCodec: RpcCodec<TestRequest>(TestRequest.fromJson),
      responseCodec: RpcCodec<TestResponse>(TestResponse.fromJson),
    );

    addClientStreamMethod<TestRequest, TestResponse>(
      methodName: 'ClientStreamMethod',
      handler: (requests, {context}) async {
        final messages = <String>[];

        await for (final request in requests) {
          messages.add(request.message);
        }

        callLog.add('ClientStreamMethod: ${messages.join(", ")}');
        return TestResponse('Received: ${messages.join(", ")}');
      },
      requestCodec: RpcCodec<TestRequest>(TestRequest.fromJson),
      responseCodec: RpcCodec<TestResponse>(TestResponse.fromJson),
    );

    addBidirectionalMethod<TestRequest, TestResponse>(
      methodName: 'BidirectionalMethod',
      handler: (requests, {context}) async* {
        callLog.add('BidirectionalMethod: started');

        await for (final request in requests) {
          callLog.add('BidirectionalMethod: ${request.message}');
          yield TestResponse('Echo: ${request.message}');
          await Future<void>.delayed(Duration(milliseconds: 1));
        }

        callLog.add('BidirectionalMethod: finished');
      },
      requestCodec: RpcCodec<TestRequest>(TestRequest.fromJson),
      responseCodec: RpcCodec<TestResponse>(TestResponse.fromJson),
    );
  }
}

void main() {
  group('RpcCallerEndpoint', () {
    late IRpcTransport clientTransport;
    late IRpcTransport serverTransport;
    late RpcResponderEndpoint responderEndpoint;
    late RpcCallerEndpoint callerEndpoint;
    late TestService testService;

    setUp(() {
      final pair = RpcInMemoryTransport.pair();
      clientTransport = pair.$1;
      serverTransport = pair.$2;

      responderEndpoint = RpcResponderEndpoint(transport: serverTransport);
      callerEndpoint = RpcCallerEndpoint(transport: clientTransport);

      // Register the service under test.
      testService = TestService();
      responderEndpoint.registerServiceContract(testService);

      // IMPORTANT: start responderEndpoint, or nothing handles the requests.
      responderEndpoint.start();
    });

    tearDown(() async {
      await responderEndpoint.close();
      await callerEndpoint.close();
      testService.callLog.clear();
    });

    test('a unary request comes back with the right answer', () async {
      // Send a unary request.
      final response = await callerEndpoint
          .unaryRequest<TestRequest, TestResponse>(
            serviceName: 'TestService',
            methodName: 'UnaryMethod',
            requestCodec: RpcCodec<TestRequest>(TestRequest.fromJson),
            responseCodec: RpcCodec<TestResponse>(TestResponse.fromJson),
            request: TestRequest('Hello from test'),
          );

      // Check the answer.
      expect(response.message, equals('Reply to: Hello from test'));
      expect(testService.callLog, contains('UnaryMethod: Hello from test'));
    });

    test('a server stream delivers every message', () async {
      final stream = callerEndpoint.serverStream<TestRequest, TestResponse>(
        serviceName: 'TestService',
        methodName: 'ServerStreamMethod',
        requestCodec: RpcCodec<TestRequest>(TestRequest.fromJson),
        responseCodec: RpcCodec<TestResponse>(TestResponse.fromJson),
        request: TestRequest('Stream request'),
      );

      final responses = await stream
          .take(3)
          .toList()
          .timeout(const Duration(seconds: 5));

      expect(responses.length, 3);
      expect(responses[0].message, equals('Reply 1 to: Stream request'));
      expect(responses[1].message, equals('Reply 2 to: Stream request'));
      expect(responses[2].message, equals('Reply 3 to: Stream request'));
      expect(
        testService.callLog,
        contains('ServerStreamMethod: Stream request'),
      );
    });

    test('a client stream sends every message', () async {
      // Stream.fromIterable, for simplicity.
      final requestStream = Stream.fromIterable([
        TestRequest('Message 1'),
        TestRequest('Message 2'),
        TestRequest('Message 3'),
      ]);

      // Get the call function.
      final getResponse = callerEndpoint
          .clientStream<TestRequest, TestResponse>(
            serviceName: 'TestService',
            methodName: 'ClientStreamMethod',
            requestCodec: RpcCodec<TestRequest>(TestRequest.fromJson),
            responseCodec: RpcCodec<TestResponse>(TestResponse.fromJson),
          );

      // Call it: this sends every message and waits for the answer.
      final response = await getResponse(requestStream).timeout(
        Duration(seconds: 10),
        onTimeout: () {
          throw TimeoutException('timed out waiting for the answer');
        },
      );

      // Check the result.
      expect(
        response.message,
        equals('Received: Message 1, Message 2, Message 3'),
      );
      expect(
        testService.callLog,
        contains('ClientStreamMethod: Message 1, Message 2, Message 3'),
      );
    });

    test('a bidirectional stream carries both directions', () async {
      // The request stream.
      final controller = StreamController<TestRequest>();

      // Open the bidirectional call.
      final responseStream = callerEndpoint
          .bidirectionalStream<TestRequest, TestResponse>(
            serviceName: 'TestService',
            methodName: 'BidirectionalMethod',
            requestCodec: RpcCodec<TestRequest>(TestRequest.fromJson),
            responseCodec: RpcCodec<TestResponse>(TestResponse.fromJson),
            requests: controller.stream,
          );

      // IMPORTANT: listen for answers BEFORE sending any request.
      final responsesFuture = responseStream.take(3).toList();

      // A short pause before sending, for stability.
      await Future<void>.delayed(Duration(milliseconds: 1));

      // Send the requests, spaced out.
      controller.add(TestRequest('Bi Message 1'));
      await Future<void>.delayed(Duration(milliseconds: 1));

      controller.add(TestRequest('Bi Message 2'));
      await Future<void>.delayed(Duration(milliseconds: 1));

      controller.add(TestRequest('Bi Message 3'));
      await Future<void>.delayed(Duration(milliseconds: 1));

      // Close the controller: that is the end of the request stream.
      await controller.close();

      final allResponses = await responsesFuture.timeout(
        const Duration(seconds: 5),
      );

      expect(allResponses.length, equals(3));
      expect(allResponses[0].message, equals('Echo: Bi Message 1'));
      expect(allResponses[1].message, equals('Echo: Bi Message 2'));
      expect(allResponses[2].message, equals('Echo: Bi Message 3'));

      expect(testService.callLog, contains('BidirectionalMethod: started'));
      expect(
        testService.callLog,
        contains('BidirectionalMethod: Bi Message 1'),
      );
      expect(
        testService.callLog,
        contains('BidirectionalMethod: Bi Message 2'),
      );
      expect(
        testService.callLog,
        contains('BidirectionalMethod: Bi Message 3'),
      );
    });

    test('closing the endpoint releases its resources', () async {
      // A request before the close.
      final response = await callerEndpoint
          .unaryRequest<TestRequest, TestResponse>(
            serviceName: 'TestService',
            methodName: 'UnaryMethod',
            requestCodec: RpcCodec<TestRequest>(TestRequest.fromJson),
            responseCodec: RpcCodec<TestResponse>(TestResponse.fromJson),
            request: TestRequest('Pre-close request'),
          );

      expect(response.message, equals('Reply to: Pre-close request'));

      // Close the endpoint.
      await callerEndpoint.close();

      // It is no longer active.
      expect(callerEndpoint.isActive, isFalse);

      // Using a closed endpoint must throw.
      expect(() async {
        await callerEndpoint.unaryRequest<TestRequest, TestResponse>(
          serviceName: 'TestService',
          methodName: 'UnaryMethod',
          requestCodec: RpcCodec<TestRequest>(TestRequest.fromJson),
          responseCodec: RpcCodec<TestResponse>(TestResponse.fromJson),
          request: TestRequest('Post-close request'),
        );
      }, throwsA(isA<RpcClosedException>()));

      // Give the outstanding async work time to finish.
      await Future<void>.delayed(Duration(milliseconds: 1));
    });
  });
}
