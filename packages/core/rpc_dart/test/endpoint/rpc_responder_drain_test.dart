// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

class _Req implements IRpcSerializable {
  final String value;
  _Req(this.value);
  factory _Req.fromJson(Map<String, dynamic> json) =>
      _Req(json['value'] as String);
  @override
  Map<String, dynamic> toJson() => {'value': value};
}

class _Resp implements IRpcSerializable {
  final String value;
  _Resp(this.value);
  factory _Resp.fromJson(Map<String, dynamic> json) =>
      _Resp(json['value'] as String);
  @override
  Map<String, dynamic> toJson() => {'value': value};
}

final class _SlowService extends RpcResponderContract {
  final Completer<void> handlerStarted = Completer<void>();
  final Completer<void> handlerCanFinish = Completer<void>();

  _SlowService() : super('SlowService');

  @override
  void setup() {
    addUnaryMethod<_Req, _Resp>(
      methodName: 'Slow',
      handler: (request, {context}) async {
        handlerStarted.complete();
        final token = context?.cancellationToken;
        if (token != null && token.isCancelled) {
          throw RpcCancelledException(token.reason ?? 'cancelled');
        }
        await Future.any([
          handlerCanFinish.future,
          if (token != null) token.cancelled,
        ]);
        if (token != null && token.isCancelled) {
          throw RpcCancelledException(token.reason ?? 'cancelled');
        }
        return _Resp('done');
      },
      requestCodec: RpcCodec<_Req>(_Req.fromJson),
      responseCodec: RpcCodec<_Resp>(_Resp.fromJson),
    );
  }
}

final class _FastService extends RpcResponderContract {
  _FastService() : super('FastService');

  @override
  void setup() {
    addUnaryMethod<_Req, _Resp>(
      methodName: 'Echo',
      handler: (request, {context}) async => _Resp('echo: ${request.value}'),
      requestCodec: RpcCodec<_Req>(_Req.fromJson),
      responseCodec: RpcCodec<_Resp>(_Resp.fromJson),
    );
  }
}

void main() {
  group('RpcResponderEndpoint drain', () {
    late RpcCallerEndpoint caller;
    late RpcResponderEndpoint responder;

    setUp(() {
      final pair = RpcInMemoryTransport.pair();
      caller = RpcCallerEndpoint(transport: pair.$1);
      responder = RpcResponderEndpoint(transport: pair.$2);
    });

    tearDown(() async {
      await caller.close();
      await responder.close();
    });

    test('new streams are rejected with UNAVAILABLE during drain', () async {
      responder.registerServiceContract(_FastService());
      responder.start();

      // Drain with no active streams completes immediately.
      await responder.drain(timeout: const Duration(seconds: 1));

      // Now try to make a call — should get UNAVAILABLE.
      await expectLater(
        caller.unaryRequest<_Req, _Resp>(
          serviceName: 'FastService',
          methodName: 'Echo',
          request: _Req('hello'),
          requestCodec: RpcCodec<_Req>(_Req.fromJson),
          responseCodec: RpcCodec<_Resp>(_Resp.fromJson),
        ),
        throwsA(
          isA<RpcStatusException>()
              .having((e) => e.statusCode, 'statusCode', RpcStatus.unavailable),
        ),
      );
    });

    test('active stream cancellation token fires on drain', () async {
      final service = _SlowService();
      responder.registerServiceContract(service);
      responder.start();

      // Start a slow call that blocks in the handler.
      final callFuture = caller.unaryRequest<_Req, _Resp>(
        serviceName: 'SlowService',
        methodName: 'Slow',
        request: _Req('hello'),
        requestCodec: RpcCodec<_Req>(_Req.fromJson),
        responseCodec: RpcCodec<_Resp>(_Resp.fromJson),
      );

      // Wait for the handler to start processing.
      await service.handlerStarted.future;

      // Now drain — this should cancel the active stream's context.
      final drainFuture = responder.drain(timeout: const Duration(seconds: 2));

      // The call should fail (handler throws on cancellation -> error trailer).
      await expectLater(callFuture, throwsA(anything));

      await drainFuture;

      // After drain, open streams should be 0.
      final metrics = responder.collectEndpointMetrics();
      expect(metrics['openStreams'], 0);
    });

    test('isDraining is true after drain() is called', () async {
      responder.start();
      expect(responder.isDraining, isFalse);
      await responder.drain(timeout: const Duration(milliseconds: 100));
      expect(responder.isDraining, isTrue);
    });
  });
}
