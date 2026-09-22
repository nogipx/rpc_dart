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

/// A responder contract with deliberately slow methods.
final class TestService extends RpcResponderContract {
  final List<String> callLog = [];

  TestService() : super('TestService');

  @override
  void setup() {
    addUnaryMethod<TestRequest, TestResponse>(
      methodName: 'SlowMethod',
      handler: (request, {context}) async {
        callLog.add('SlowMethod started: ${request.message}');

        // A long operation that checks for cancellation as it goes.
        for (int i = 0; i < 100; i++) {
          context?.cancellationToken?.throwIfCancelled();
          await Future<void>.delayed(Duration(milliseconds: 10));
        }

        callLog.add('SlowMethod completed: ${request.message}');
        return TestResponse('Completed: ${request.message}');
      },
      requestCodec: RpcCodec<TestRequest>(TestRequest.fromJson),
      responseCodec: RpcCodec<TestResponse>(TestResponse.fromJson),
    );
    addServerStreamMethod<TestRequest, TestResponse>(
      methodName: 'SlowStreamMethod',
      handler: (request, {context}) async* {
        callLog.add('SlowStreamMethod started: ${request.message}');

        for (int i = 0; i < 10; i++) {
          context?.cancellationToken?.throwIfCancelled();
          yield TestResponse('Item $i for: ${request.message}');
          await Future<void>.delayed(Duration(milliseconds: 50));
        }

        callLog.add('SlowStreamMethod completed: ${request.message}');
      },
      requestCodec: RpcCodec<TestRequest>(TestRequest.fromJson),
      responseCodec: RpcCodec<TestResponse>(TestResponse.fromJson),
    );
    addUnaryMethod<TestRequest, TestResponse>(
      methodName: 'FastMethod',
      handler: (request, {context}) async {
        callLog.add('FastMethod: ${request.message}');
        return TestResponse('Fast reply to: ${request.message}');
      },
      requestCodec: RpcCodec<TestRequest>(TestRequest.fromJson),
      responseCodec: RpcCodec<TestResponse>(TestResponse.fromJson),
    );
  }
}

void main() {
  group('RpcCallerEndpoint Cancellation Tests', () {
    late RpcCallerEndpoint callerEndpoint;
    late RpcResponderEndpoint responderEndpoint;
    late TestService testService;

    setUp(() async {
      // A transport pair.
      final (clientTransport, serverTransport) = RpcInMemoryTransport.pair();

      // The endpoints.
      callerEndpoint = RpcCallerEndpoint(transport: clientTransport);
      responderEndpoint = RpcResponderEndpoint(transport: serverTransport);

      // Build and register the service under test.
      testService = TestService();
      responderEndpoint.registerServiceContract(testService);
      responderEndpoint.start();
    });

    tearDown(() async {
      await responderEndpoint.close();
      await callerEndpoint.close();
      testService.callLog.clear();
    });

    test('cancelling one unary method by key', () async {
      final future = callerEndpoint.unaryRequest<TestRequest, TestResponse>(
        serviceName: 'TestService',
        methodName: 'FastMethod',
        requestCodec: RpcCodec<TestRequest>(TestRequest.fromJson),
        responseCodec: RpcCodec<TestResponse>(TestResponse.fromJson),
        request: TestRequest('operation 1'),
      );

      callerEndpoint.cancelMethod('TestService', 'FastMethod');

      await expectLater(future, throwsA(isA<RpcCancelledException>()));
    });

    test('cancelling every method of one service', () async {
      // Start several methods.
      final future1 = callerEndpoint.unaryRequest<TestRequest, TestResponse>(
        serviceName: 'TestService',
        methodName: 'SlowMethod',
        requestCodec: RpcCodec<TestRequest>(TestRequest.fromJson),
        responseCodec: RpcCodec<TestResponse>(TestResponse.fromJson),
        request: TestRequest('operation 1'),
      );

      final future2 = callerEndpoint.unaryRequest<TestRequest, TestResponse>(
        serviceName: 'TestService',
        methodName: 'FastMethod',
        requestCodec: RpcCodec<TestRequest>(TestRequest.fromJson),
        responseCodec: RpcCodec<TestResponse>(TestResponse.fromJson),
        request: TestRequest('operation 2'),
      );

      // A short wait.
      await Future<void>.delayed(Duration(milliseconds: 50));

      // Cancel everything on the service.
      callerEndpoint.cancelServiceMethods('TestService', 'Service shutdown');

      // The first method saw the cancellation.
      await expectLater(
        future1,
        throwsA(
          predicate<RpcCancelledException>(
            (e) => e.message == 'Service shutdown',
          ),
        ),
      );

      // FastMethod may finish before the cancel lands, so accept either.
      try {
        await future2;
      } on RpcCancelledException {
        // Expected, if the method was cancelled.
      }
    });

    test('cancelling every live method', () async {
      // Start a method.
      final future = callerEndpoint.unaryRequest<TestRequest, TestResponse>(
        serviceName: 'TestService',
        methodName: 'SlowMethod',
        requestCodec: RpcCodec<TestRequest>(TestRequest.fromJson),
        responseCodec: RpcCodec<TestResponse>(TestResponse.fromJson),
        request: TestRequest('operation'),
      );

      // A short wait.
      await Future<void>.delayed(Duration(milliseconds: 50));

      // Cancel everything.
      callerEndpoint.cancelAllMethods('Global cancellation');

      // It was cancelled.
      await expectLater(
        future,
        throwsA(
          predicate<RpcCancelledException>(
            (e) => e.message == 'Global cancellation',
          ),
        ),
      );
    });

    test('cancelling a method that is not running', () async {
      // Try to cancel a method nobody started.
      final cancelled = callerEndpoint.cancelMethod(
        'TestService',
        'NonExistentMethod',
      );
      expect(cancelled, 0); // The return value is a count of cancelled tokens.
    });

    test('getCancellationTokensForMethod reports the live tokens', () async {
      // Start a method.
      final future = callerEndpoint.unaryRequest<TestRequest, TestResponse>(
        serviceName: 'TestService',
        methodName: 'SlowMethod',
        requestCodec: RpcCodec<TestRequest>(TestRequest.fromJson),
        responseCodec: RpcCodec<TestResponse>(TestResponse.fromJson),
        request: TestRequest('operation'),
      );

      // How many calls are live.
      final activeCallsCount = callerEndpoint
          .getCancellationTokensForMethod('TestService', 'SlowMethod')
          .length;
      expect(activeCallsCount, 1);

      // Cancel every call of that method.
      final cancelledCount = callerEndpoint.cancelMethod(
        'TestService',
        'SlowMethod',
      );
      expect(cancelledCount, 1);

      // No live calls remain.
      final activeCallsCountAfter = callerEndpoint
          .getCancellationTokensForMethod('TestService', 'SlowMethod')
          .length;
      expect(activeCallsCountAfter, 0);

      // And the call threw.
      await expectLater(
        future,
        throwsA(
          predicate<RpcCancelledException>(
            (e) => e.message == 'Method cancelled by user',
          ),
        ),
      );
    });

    test('several calls of one method get separate tokens', () async {
      // Start several calls of the same method.
      final future1 = callerEndpoint.unaryRequest<TestRequest, TestResponse>(
        serviceName: 'TestService',
        methodName: 'SlowMethod',
        requestCodec: RpcCodec<TestRequest>(TestRequest.fromJson),
        responseCodec: RpcCodec<TestResponse>(TestResponse.fromJson),
        request: TestRequest('operation 1'),
      );

      // A short gap between them.
      await Future<void>.delayed(Duration(milliseconds: 10));

      final future2 = callerEndpoint.unaryRequest<TestRequest, TestResponse>(
        serviceName: 'TestService',
        methodName: 'SlowMethod',
        requestCodec: RpcCodec<TestRequest>(TestRequest.fromJson),
        responseCodec: RpcCodec<TestResponse>(TestResponse.fromJson),
        request: TestRequest('operation 2'),
      );

      // Long enough for both requests to register.
      await Future<void>.delayed(Duration(milliseconds: 100));

      // Two tokens for the one method.
      final tokens = callerEndpoint.getCancellationTokensForMethod(
        'TestService',
        'SlowMethod',
      );
      expect(tokens.length, 2);

      // Cancel every call of that method.
      final cancelledCount = callerEndpoint.cancelMethod(
        'TestService',
        'SlowMethod',
      );
      expect(cancelledCount, 2);

      // Both calls were cancelled.
      await expectLater(future1, throwsA(isA<RpcCancelledException>()));

      await expectLater(future2, throwsA(isA<RpcCancelledException>()));
    });

    test('cancelling with a caller-supplied reason', () async {
      final future = callerEndpoint.unaryRequest<TestRequest, TestResponse>(
        serviceName: 'TestService',
        methodName: 'SlowMethod',
        requestCodec: RpcCodec<TestRequest>(TestRequest.fromJson),
        responseCodec: RpcCodec<TestResponse>(TestResponse.fromJson),
        request: TestRequest('operation'),
      );

      await Future<void>.delayed(Duration(milliseconds: 50));

      final customReason = 'User clicked cancel button';
      callerEndpoint.cancelMethod('TestService', 'SlowMethod', customReason);

      await expectLater(
        future,
        throwsA(
          predicate<RpcCancelledException>((e) => e.message == customReason),
        ),
      );
    });
  });
}
