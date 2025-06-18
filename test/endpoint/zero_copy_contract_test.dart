// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: LGPL-3.0-or-later

import 'package:test/test.dart';
import 'package:rpc_dart/rpc_dart.dart';

/// Тестовый класс запроса для zero-copy
final class TestZeroCopyRequest {
  final String message;
  TestZeroCopyRequest(this.message);

  @override
  String toString() => 'TestZeroCopyRequest($message)';
}

/// Тестовый класс ответа для zero-copy
final class TestZeroCopyResponse {
  final String result;
  TestZeroCopyResponse(this.result);

  @override
  String toString() => 'TestZeroCopyResponse($result)';
}

/// Тестовый сервис с zero-copy методами
final class ZeroCopyTestService extends RpcResponderContract {
  final List<String> callLog = [];

  ZeroCopyTestService() : super('ZeroCopyTestService');

  @override
  void setup() {
    // 🚀 Zero-copy унарный метод
    addUnaryMethod<TestZeroCopyRequest, TestZeroCopyResponse>(
      methodName: 'ZeroCopyUnary',
      handler: (request, {context}) async {
        callLog.add('ZeroCopyUnary: ${request.message}');
        return TestZeroCopyResponse('ZeroCopy reply to: ${request.message}');
      },
      description: 'Zero-copy unary method',
    );

    // 🚀 Zero-copy серверный стрим
    addServerStreamMethod<TestZeroCopyRequest, TestZeroCopyResponse>(
      methodName: 'ZeroCopyServerStream',
      handler: (request, {context}) async* {
        callLog.add('ZeroCopyServerStream: ${request.message}');
        for (int i = 1; i <= 3; i++) {
          yield TestZeroCopyResponse(
              'Stream response $i for: ${request.message}');
        }
      },
      description: 'Zero-copy server stream method',
    );
  }
}

void main() {
  group('🚀 Zero-Copy Contract Tests', () {
    late IRpcTransport clientTransport;
    late IRpcTransport serverTransport;
    late RpcResponderEndpoint responderEndpoint;
    late RpcCallerEndpoint callerEndpoint;
    late ZeroCopyTestService zeroCopyService;

    setUp(() {
      final pair = RpcInMemoryTransport.pair();
      clientTransport = pair.$1;
      serverTransport = pair.$2;

      responderEndpoint = RpcResponderEndpoint(transport: serverTransport);
      callerEndpoint = RpcCallerEndpoint(transport: clientTransport);

      zeroCopyService = ZeroCopyTestService();
    });

    tearDown(() async {
      await responderEndpoint.close();
      await callerEndpoint.close();
      zeroCopyService.callLog.clear();
    });

    test('Zero-copy методы регистрируются правильно', () {
      // Регистрируем сервис с zero-copy методами
      responderEndpoint.registerServiceContract(zeroCopyService);
      responderEndpoint.start();

      // Проверяем что сервис зарегистрирован
      expect(responderEndpoint.registeredContracts,
          contains('ZeroCopyTestService'));

      // Проверяем что zero-copy методы зарегистрированы как обычные методы
      expect(responderEndpoint.registeredMethods,
          contains('ZeroCopyTestService.ZeroCopyUnary'));
      expect(responderEndpoint.registeredMethods,
          contains('ZeroCopyTestService.ZeroCopyServerStream'));
    });

    test('Zero-copy унарный метод работает через endpoint', () async {
      // Регистрируем сервис
      responderEndpoint.registerServiceContract(zeroCopyService);
      responderEndpoint.start();

      // Вызываем zero-copy метод
      final response = await callerEndpoint
          .unaryRequest<TestZeroCopyRequest, TestZeroCopyResponse>(
        serviceName: 'ZeroCopyTestService',
        methodName: 'ZeroCopyUnary',
        request: TestZeroCopyRequest('zero-copy test'),
      );

      // Проверяем результат
      expect(response.result, equals('ZeroCopy reply to: zero-copy test'));
      expect(
          zeroCopyService.callLog, contains('ZeroCopyUnary: zero-copy test'));
    });

    test('Zero-copy серверный стрим работает через endpoint', () async {
      // Регистрируем сервис
      responderEndpoint.registerServiceContract(zeroCopyService);
      responderEndpoint.start();

      // Вызываем zero-copy серверный стрим
      final responses = <TestZeroCopyResponse>[];

      await for (final response in callerEndpoint
          .serverStream<TestZeroCopyRequest, TestZeroCopyResponse>(
        serviceName: 'ZeroCopyTestService',
        methodName: 'ZeroCopyServerStream',
        request: TestZeroCopyRequest('stream test'),
      )) {
        responses.add(response);
      }

      // Проверяем результаты
      expect(responses.length, equals(3));
      expect(responses[0].result, equals('Stream response 1 for: stream test'));
      expect(responses[1].result, equals('Stream response 2 for: stream test'));
      expect(responses[2].result, equals('Stream response 3 for: stream test'));
      expect(zeroCopyService.callLog,
          contains('ZeroCopyServerStream: stream test'));
    });

    test('Контракт содержит zero-copy методы', () {
      // Вызываем setup явно чтобы методы зарегистрировались
      zeroCopyService.setup();

      // Проверяем что zero-copy методы есть в контракте
      final zeroCopyMethods = zeroCopyService.zeroCopyMethods;

      expect(zeroCopyMethods.keys, contains('ZeroCopyUnary'));
      expect(zeroCopyMethods.keys, contains('ZeroCopyServerStream'));

      final unaryMethod = zeroCopyMethods['ZeroCopyUnary']!;
      expect(unaryMethod.type, equals(RpcMethodType.unaryRequest));
      expect(unaryMethod.description, contains('ZERO-COPY'));

      final serverStreamMethod = zeroCopyMethods['ZeroCopyServerStream']!;
      expect(serverStreamMethod.type, equals(RpcMethodType.serverStream));
      expect(serverStreamMethod.description, contains('ZERO-COPY'));
    });
  });
}
