// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

void main() {
  group('RpcRetryInterceptor', () {
    late RpcMiddlewareContext callContext;

    setUp(() {
      final (clientTransport, _) = RpcChannelTransport.memoryPair();
      final endpoint = RpcCallerEndpoint(transport: clientTransport);
      callContext = RpcMiddlewareContext(
        endpoint: endpoint,
        serviceName: 'TestService',
        methodName: 'TestMethod',
        context: RpcContext.empty(),
      );
    });

    test('passes through on first success', () async {
      final interceptor = RpcRetryInterceptor(maxAttempts: 3);
      var callCount = 0;

      final result = await interceptor.interceptUnary<String, String>(
        callContext,
        'request',
        (ctx, req) async {
          callCount++;
          return 'ok';
        },
      );

      expect(result, 'ok');
      expect(callCount, 1);
    });

    test('retries on failure up to maxAttempts', () async {
      final interceptor = RpcRetryInterceptor(
        maxAttempts: 3,
        backoff: FixedBackoff(Duration(milliseconds: 10)),
      );
      var callCount = 0;

      try {
        await interceptor.interceptUnary<String, String>(
          callContext,
          'request',
          (ctx, req) async {
            callCount++;
            throw RpcException('fail');
          },
        );
        fail('Should have thrown');
      } on RpcException catch (e) {
        expect(e.message, 'fail');
      }

      expect(callCount, 3);
    });

    test('succeeds on retry after transient failure', () async {
      final interceptor = RpcRetryInterceptor(
        maxAttempts: 3,
        backoff: FixedBackoff(Duration(milliseconds: 10)),
      );
      var callCount = 0;

      final result = await interceptor.interceptUnary<String, String>(
        callContext,
        'request',
        (ctx, req) async {
          callCount++;
          if (callCount < 3) throw RpcException('transient');
          return 'recovered';
        },
      );

      expect(result, 'recovered');
      expect(callCount, 3);
    });

    test('does not retry RpcCancelledException', () async {
      final interceptor = RpcRetryInterceptor(
        maxAttempts: 3,
        backoff: FixedBackoff(Duration(milliseconds: 10)),
      );
      var callCount = 0;

      try {
        await interceptor.interceptUnary<String, String>(
          callContext,
          'request',
          (ctx, req) async {
            callCount++;
            throw const RpcCancelledException('cancelled');
          },
        );
        fail('Should have thrown');
      } on RpcCancelledException {
        // expected
      }

      expect(callCount, 1); // No retry.
    });

    test('does not retry RpcDeadlineExceededException', () async {
      final interceptor = RpcRetryInterceptor(
        maxAttempts: 3,
        backoff: FixedBackoff(Duration(milliseconds: 10)),
      );
      var callCount = 0;

      try {
        await interceptor.interceptUnary<String, String>(
          callContext,
          'request',
          (ctx, req) async {
            callCount++;
            throw RpcDeadlineExceededException(DateTime.now(), Duration.zero);
          },
        );
        fail('Should have thrown');
      } on RpcDeadlineExceededException {
        // expected
      }

      expect(callCount, 1);
    });

    test('respects custom retryOn predicate', () async {
      final interceptor = RpcRetryInterceptor(
        maxAttempts: 3,
        backoff: FixedBackoff(Duration(milliseconds: 10)),
        retryOn: (e) => e is RpcException && e.message == 'retry-me',
      );
      var callCount = 0;

      // Should NOT retry — predicate returns false.
      try {
        await interceptor.interceptUnary<String, String>(
          callContext,
          'request',
          (ctx, req) async {
            callCount++;
            throw RpcException('do-not-retry');
          },
        );
        fail('Should have thrown');
      } on RpcException {
        // expected
      }
      expect(callCount, 1);

      // Should retry — predicate returns true.
      callCount = 0;
      try {
        await interceptor.interceptUnary<String, String>(
          callContext,
          'request',
          (ctx, req) async {
            callCount++;
            throw RpcException('retry-me');
          },
        );
        fail('Should have thrown');
      } on RpcException {
        // expected
      }
      expect(callCount, 3);
    });

    test('does not retry when deadline is already expired', () async {
      final expiredContext = RpcContext.withDeadline(
        DateTime.now().subtract(Duration(seconds: 1)),
      );
      callContext.updateContext(expiredContext);

      final interceptor = RpcRetryInterceptor(
        maxAttempts: 3,
        backoff: FixedBackoff(Duration(milliseconds: 10)),
      );
      var callCount = 0;

      try {
        await interceptor.interceptUnary<String, String>(
          callContext,
          'request',
          (ctx, req) async {
            callCount++;
            throw RpcException('fail');
          },
        );
        fail('Should have thrown');
      } on RpcException {
        // expected
      }

      expect(callCount, 1);
    });

    test('maxAttempts 1 means no retries', () async {
      final interceptor = RpcRetryInterceptor(maxAttempts: 1);
      var callCount = 0;

      try {
        await interceptor.interceptUnary<String, String>(
          callContext,
          'request',
          (ctx, req) async {
            callCount++;
            throw RpcException('fail');
          },
        );
        fail('Should have thrown');
      } on RpcException {
        // expected
      }

      expect(callCount, 1);
    });

    test('integration: retry via endpoint', () async {
      final (clientTransport, serverTransport) =
          RpcChannelTransport.memoryPair();

      final caller = RpcCallerEndpoint(transport: clientTransport);
      final responder = RpcResponderEndpoint(transport: serverTransport);

      var serverCallCount = 0;

      responder.registerServiceContract(
        _FailThenSucceedContract(
          failCount: 2,
          onCall: () => serverCallCount++,
        ),
      );
      responder.start();

      caller.addInterceptor(RpcRetryInterceptor(
        maxAttempts: 4,
        backoff: FixedBackoff(Duration(milliseconds: 10)),
      ));

      final response = await caller.unaryRequest<_TestRequest, _TestResponse>(
        serviceName: 'TestService',
        methodName: 'Echo',
        requestCodec: _TestRequest.codec,
        responseCodec: _TestResponse.codec,
        request: _TestRequest('hello'),
      );

      expect(response.value, 'hello');
      expect(serverCallCount, 3); // 2 failures + 1 success

      await caller.close();
      await responder.close();
    });
  });
}

// ---------------------------------------------------------------------------
// Test helpers
// ---------------------------------------------------------------------------

final class _TestRequest implements IRpcSerializable {
  final String value;
  const _TestRequest(this.value);
  factory _TestRequest.fromJson(Map<String, dynamic> json) =>
      _TestRequest(json['value'] as String);
  @override
  Map<String, dynamic> toJson() => {'value': value};
  static RpcCodec<_TestRequest> get codec => RpcCodec(_TestRequest.fromJson);
}

final class _TestResponse implements IRpcSerializable {
  final String value;
  const _TestResponse(this.value);
  factory _TestResponse.fromJson(Map<String, dynamic> json) =>
      _TestResponse(json['value'] as String);
  @override
  Map<String, dynamic> toJson() => {'value': value};
  static RpcCodec<_TestResponse> get codec => RpcCodec(_TestResponse.fromJson);
}

final class _FailThenSucceedContract extends RpcResponderContract {
  final int failCount;
  final void Function() onCall;
  int _callCount = 0;

  _FailThenSucceedContract({required this.failCount, required this.onCall})
      : super('TestService');

  @override
  void setup() {
    addUnaryMethod<_TestRequest, _TestResponse>(
      methodName: 'Echo',
      handler: _echo,
      requestCodec: _TestRequest.codec,
      responseCodec: _TestResponse.codec,
    );
  }

  Future<_TestResponse> _echo(
    _TestRequest request, {
    RpcContext? context,
  }) async {
    onCall();
    _callCount++;
    if (_callCount <= failCount) {
      throw RpcException('transient failure');
    }
    return _TestResponse(request.value);
  }
}
