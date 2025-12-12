// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

final class _TestRequest implements IRpcSerializable {
  final String value;

  _TestRequest(this.value);

  factory _TestRequest.fromJson(Map<String, dynamic> json) {
    return _TestRequest(json['value'] as String);
  }

  @override
  Map<String, dynamic> toJson() => {'value': value};
}

final class _TestResponse implements IRpcSerializable {
  final String value;

  _TestResponse(this.value);

  factory _TestResponse.fromJson(Map<String, dynamic> json) {
    return _TestResponse(json['value'] as String);
  }

  @override
  Map<String, dynamic> toJson() => {'value': value};
}

final class _EchoService extends RpcResponderContract {
  static const serviceId = 'EchoService';
  static const unaryMethodId = 'EchoUnary';
  static const serverStreamMethodId = 'EchoServerStream';

  _EchoService() : super(serviceId);

  @override
  void setup() {
    addUnaryMethod<_TestRequest, _TestResponse>(
      methodName: unaryMethodId,
      requestCodec: RpcCodec<_TestRequest>(_TestRequest.fromJson),
      responseCodec: RpcCodec<_TestResponse>(_TestResponse.fromJson),
      handler: (request, {context}) async => _TestResponse(request.value),
    );

    addServerStreamMethod<_TestRequest, _TestResponse>(
      methodName: serverStreamMethodId,
      requestCodec: RpcCodec<_TestRequest>(_TestRequest.fromJson),
      responseCodec: RpcCodec<_TestResponse>(_TestResponse.fromJson),
      handler: (request, {context}) async* {
        yield _TestResponse('${request.value}:1');
        yield _TestResponse('${request.value}:2');
      },
    );
  }
}

void main() {
  group('RpcCallerEndpoint cancellation registry cleanup', () {
    late IRpcTransport clientTransport;
    late IRpcTransport serverTransport;
    late RpcCallerEndpoint callerEndpoint;
    late RpcResponderEndpoint responderEndpoint;

    setUp(() {
      final pair = RpcInMemoryTransport.pair();
      clientTransport = pair.$1;
      serverTransport = pair.$2;
      callerEndpoint = RpcCallerEndpoint(transport: clientTransport);
      responderEndpoint = RpcResponderEndpoint(transport: serverTransport)
        ..registerServiceContract(_EchoService())
        ..start();
    });

    tearDown(() async {
      await responderEndpoint.close();
      await callerEndpoint.close();
    });

    test('unaryRequest clears tracked token after completion', () async {
      final response =
          await callerEndpoint.unaryRequest<_TestRequest, _TestResponse>(
        serviceName: _EchoService.serviceId,
        methodName: _EchoService.unaryMethodId,
        requestCodec: RpcCodec<_TestRequest>(_TestRequest.fromJson),
        responseCodec: RpcCodec<_TestResponse>(_TestResponse.fromJson),
        request: _TestRequest('ok'),
      );
      expect(response.value, equals('ok'));

      expect(
        callerEndpoint.getCancellationTokensForMethod(
          _EchoService.serviceId,
          _EchoService.unaryMethodId,
        ),
        isEmpty,
      );

      final health = await callerEndpoint.health();
      expect(health.endpointStatus.details['pendingRequests'], equals(0));
    });

    test('serverStream clears tracked token after stream completion', () async {
      final results = await callerEndpoint
          .serverStream<_TestRequest, _TestResponse>(
            serviceName: _EchoService.serviceId,
            methodName: _EchoService.serverStreamMethodId,
            requestCodec: RpcCodec<_TestRequest>(_TestRequest.fromJson),
            responseCodec: RpcCodec<_TestResponse>(_TestResponse.fromJson),
            request: _TestRequest('ok'),
          )
          .map((res) => res.value)
          .toList();

      expect(results, equals(['ok:1', 'ok:2']));

      expect(
        callerEndpoint.getCancellationTokensForMethod(
          _EchoService.serviceId,
          _EchoService.serverStreamMethodId,
        ),
        isEmpty,
      );

      final health = await callerEndpoint.health();
      expect(health.endpointStatus.details['pendingRequests'], equals(0));
    });
  });
}
