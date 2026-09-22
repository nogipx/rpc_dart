// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

// The models under test.
class TestRequest implements IRpcSerializable {
  final String message;
  final List<String> data;

  TestRequest(this.message, this.data);

  factory TestRequest.fromJson(Map<String, dynamic> json) {
    return TestRequest(
      json['message'] as String,
      (json['data'] as List).cast<String>(),
    );
  }

  @override
  Map<String, dynamic> toJson() {
    return {'message': message, 'data': data};
  }
}

class TestResponse implements IRpcSerializable {
  final String result;
  final int count;

  TestResponse(this.result, this.count);

  factory TestResponse.fromJson(Map<String, dynamic> json) {
    return TestResponse(json['result'] as String, json['count'] as int);
  }

  @override
  Map<String, dynamic> toJson() {
    return {'result': result, 'count': count};
  }
}

// The service under test.
final class TestService extends RpcResponderContract {
  TestService() : super('TestService');

  @override
  void setup() {
    addUnaryMethod<TestRequest, TestResponse>(
      methodName: 'processData',
      handler: (request, {context}) async {
        // Stand in for real work.
        final processedData = request.data
            .map((item) => item.toUpperCase())
            .toList();
        return TestResponse(
          'Processed: ${request.message}. Items: ${processedData.join(", ")}',
          request.data.length,
        );
      },
      requestCodec: RpcCodec<TestRequest>(TestRequest.fromJson),
      responseCodec: RpcCodec<TestResponse>(TestResponse.fromJson),
    );

    // A handler that always fails with UNAVAILABLE, so the test can check that
    // the zero-copy unary path propagates a typed RpcStatusException.
    addUnaryMethod<TestRequest, TestResponse>(
      methodName: 'failUnavailable',
      handler: (request, {context}) async {
        throw RpcStatusException(RpcStatus.unavailable, 'service down');
      },
      requestCodec: RpcCodec<TestRequest>(TestRequest.fromJson),
      responseCodec: RpcCodec<TestResponse>(TestResponse.fromJson),
    );
  }
}

void main() {
  group('Zero-copy endpoint', () {
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

      testService = TestService();
      responderEndpoint.registerServiceContract(testService);
      responderEndpoint.start();
    });

    tearDown(() async {
      await responderEndpoint.close();
      await callerEndpoint.close();
    });

    test('what a unary call actually puts on the wire', () async {
      print('\nlooking at what the endpoints do...');

      // A request with enough structure to be worth serializing.
      final request = TestRequest('Complex data processing', [
        'item1',
        'item2',
        'item3',
        'item4',
        'item5',
      ]);

      print('\nsending a request through the endpoint');
      print('   request: ${request.message}');
      print('   data: ${request.data}');

      // Watch what reaches the transport layer.
      final sentMessages = <RpcTransportMessage>[];

      // Subscribe on the server side before sending.
      serverTransport.incomingMessages.listen((message) {
        sentMessages.add(message);

        if (message.isSerialized && message.payload != null) {
          print('\nSERIALIZED');
          print('   serialized size: ${message.payload!.length} bytes');
          print('   Stream ID: ${message.streamId}');
          print('   EndOfStream: ${message.isEndOfStream}');
        } else if (message.isDirect && message.directPayload != null) {
          print('\nZERO-COPY');
          print('   direct object: ${message.directPayload.runtimeType}');
          print('   Stream ID: ${message.streamId}');
          print('   EndOfStream: ${message.isEndOfStream}');
        } else if (message.metadata != null) {
          print('\nmetadata:');
          print('   Headers: ${message.metadata!.headers.length}');
          print('   EndOfStream: ${message.isEndOfStream}');
        }
      });

      // Make the call.
      final response = await callerEndpoint
          .unaryRequest<TestRequest, TestResponse>(
            serviceName: 'TestService',
            methodName: 'processData',
            requestCodec: RpcCodec<TestRequest>(TestRequest.fromJson),
            responseCodec: RpcCodec<TestResponse>(TestResponse.fromJson),
            request: request,
          );

      print('\nanswer:');
      print('   result: ${response.result}');
      print('   count: ${response.count}');

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

      // The call works.
      expect(response.result, contains('Processed: Complex data processing'));
      expect(response.count, equals(5));

      // `unaryRequest` defaults to RpcDataTransferMode.auto, and on a transport
      // that can pass objects `auto` means exactly that -- codecs present or
      // not. That is the fast path this file has always asserted.
      //
      // What changed underneath it: `UnaryCaller` used to branch on
      // `transport.supportsZeroCopy` ALONE, so an explicit
      // RpcDataTransferMode.codec was ignored too. Measured on isolate with
      // codecs on both ends and maxMessageLengthBytes: 256 KiB, a 2 MiB response
      // was DELIVERED and a field `toJson` omits ARRIVED. Now only `codec`
      // forces serialization; see unary_transfer_mode_test.
      expect(
        directMessages,
        greaterThan(0),
        reason: 'auto on a zero-copy transport still passes the object',
      );
      expect(
        serializedMessages,
        equals(0),
        reason: 'nothing asked for serialization here',
      );
    });

    test('the object crosses by reference, not by copy', () async {
      print('\nwhat zero-copy means in an endpoint:');
      print('   1. the endpoint sees it is on an RpcInMemoryTransport');
      print('   2. sendDirectObject() instead of serialize() + sendMessage()');
      print('   3. the receiver reads directPayload, with no deserialize()');
      print('   4. objects cross by reference, at zero marshalling cost');

      final request = TestRequest('Direct object', ['zero', 'copy', 'test']);

      // Drive the transport layer directly.
      if (clientTransport.supportsZeroCopy) {
        final streamId = clientTransport.createStream();

        print('\na direct zero-copy call:');

        // Subscribe BEFORE sending, or the message is gone by the time we look.
        final messagesFuture = serverTransport.incomingMessages
            .where((m) => m.streamId == streamId && m.isDirect)
            .first
            .timeout(Duration(seconds: 2));

        await clientTransport.sendDirectObject(
          streamId,
          request,
          endStream: true,
        );

        final directMessage = await messagesFuture;

        expect(
          directMessage.directPayload,
          same(request),
          reason: 'it must be the same object, not a copy of it',
        );

        print('   the object crossed by reference, with no serialization');
        print('   bytes on the wire: 0');
      }
    });

    // Regression, BUG C: the zero-copy unary path (_executeUnaryCall) must
    // throw a typed RpcStatusException carrying the real status, not a wrapped
    // Exception. Otherwise the retry predicate and the circuit breaker cannot
    // see the gRPC status and the conservative retry default never fires.
    test(
      'the zero-copy unary path throws a typed RpcStatusException',
      () async {
        Object? caught;
        try {
          await callerEndpoint.unaryRequest<TestRequest, TestResponse>(
            serviceName: 'TestService',
            methodName: 'failUnavailable',
            // No codecs -> the zero-copy path through _executeUnaryCall.
            request: TestRequest('boom', const []),
          );
          fail('it should have thrown');
        } catch (e) {
          caught = e;
        }

        expect(
          caught,
          isA<RpcStatusException>(),
          reason: 'a typed RpcStatusException, not a bare Exception',
        );
        final ex = caught as RpcStatusException;
        expect(ex.statusCode, RpcStatus.unavailable);

        // The default retry predicate must fire on this status.
        final interceptor = RpcRetryInterceptor(maxAttempts: 3);
        var attempts = 0;
        try {
          await interceptor.interceptUnary<TestRequest, TestResponse>(
            RpcMiddlewareContext(
              endpoint: callerEndpoint,
              serviceName: 'TestService',
              methodName: 'failUnavailable',
              context: RpcContext.empty(),
            ),
            TestRequest('boom', const []),
            (ctx, req) async {
              attempts++;
              throw ex;
            },
          );
          fail('it should have thrown once the attempts ran out');
        } on RpcStatusException catch (e) {
          expect(e.statusCode, RpcStatus.unavailable);
        }
        expect(
          attempts,
          3,
          reason: 'the default retry must repeat on UNAVAILABLE',
        );
      },
    );
  });
}
