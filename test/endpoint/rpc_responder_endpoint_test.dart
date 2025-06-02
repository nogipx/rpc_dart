// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: LGPL-3.0-or-later

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

/// Тестовый запрос
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

/// Тестовый ответ
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

/// Тестовый контракт для responder
final class TestService extends RpcResponderContract {
  final List<String> callLog = [];

  TestService() : super('TestService');

  @override
  void setup() {
    addUnaryMethod<TestRequest, TestResponse>(
      methodName: 'UnaryMethod',
      handler: (request) async {
        callLog.add('UnaryMethod: ${request.message}');
        return TestResponse('Reply to: ${request.message}');
      },
      requestCodec: RpcCodec<TestRequest>(TestRequest.fromJson),
      responseCodec: RpcCodec<TestResponse>(TestResponse.fromJson),
    );

    addServerStreamMethod<TestRequest, TestResponse>(
      methodName: 'ServerStreamMethod',
      handler: (request) async* {
        callLog.add('ServerStreamMethod: ${request.message}');
        for (int i = 0; i < 3; i++) {
          yield TestResponse('Reply ${i + 1} to: ${request.message}');
          await Future.delayed(Duration(milliseconds: 10));
        }
      },
      requestCodec: RpcCodec<TestRequest>(TestRequest.fromJson),
      responseCodec: RpcCodec<TestResponse>(TestResponse.fromJson),
    );
  }
}

/// Подконтракт для тестирования регистрации подконтрактов
final class SubService extends RpcResponderContract {
  final List<String> callLog = [];

  SubService() : super('SubService');

  @override
  void setup() {
    addUnaryMethod<TestRequest, TestResponse>(
      methodName: 'SubUnaryMethod',
      handler: (request) async {
        callLog.add('SubUnaryMethod: ${request.message}');
        return TestResponse('SubService reply to: ${request.message}');
      },
      requestCodec: RpcCodec<TestRequest>(TestRequest.fromJson),
      responseCodec: RpcCodec<TestResponse>(TestResponse.fromJson),
    );
  }
}

/// Тестовый контракт с подконтрактами
final class ParentService extends RpcResponderContract {
  final List<String> callLog = [];
  final SubService subService = SubService();

  ParentService() : super('ParentService') {
    addSubcontract(subService);
  }

  @override
  void setup() {
    addUnaryMethod<TestRequest, TestResponse>(
      methodName: 'ParentMethod',
      handler: (request) async {
        callLog.add('ParentMethod: ${request.message}');
        return TestResponse('ParentService reply to: ${request.message}');
      },
      requestCodec: RpcCodec<TestRequest>(TestRequest.fromJson),
      responseCodec: RpcCodec<TestResponse>(TestResponse.fromJson),
    );
  }
}

void main() {
  group('RpcResponderEndpoint Тесты', () {
    late RpcInMemoryTransport clientTransport;
    late RpcInMemoryTransport serverTransport;
    late RpcResponderEndpoint responderEndpoint;
    late RpcCallerEndpoint callerEndpoint;
    late TestService testService;

    setUp(() {
      final pair = RpcInMemoryTransport.pair();
      clientTransport = pair.$1;
      serverTransport = pair.$2;

      responderEndpoint = RpcResponderEndpoint(transport: serverTransport);
      callerEndpoint = RpcCallerEndpoint(transport: clientTransport);

      // Регистрируем тестовый сервис
      testService = TestService();
    });

    tearDown(() async {
      await responderEndpoint.close();
      await callerEndpoint.close();
      testService.callLog.clear();
    });

    test('Регистрация контракта работает корректно', () {
      // Регистрируем сервис
      responderEndpoint.registerServiceContract(testService);

      // Проверяем, что сервис был зарегистрирован
      expect(responderEndpoint.registeredContracts, contains('TestService'));
      expect(responderEndpoint.registeredMethods,
          contains('TestService.UnaryMethod'));
      expect(responderEndpoint.registeredMethods,
          contains('TestService.ServerStreamMethod'));
    });

    test('Регистрация подконтрактов работает корректно', () {
      // Создаем и регистрируем сервис с подконтрактом
      final parentService = ParentService();
      responderEndpoint.registerServiceContract(parentService);

      // Проверяем, что оба сервиса зарегистрированы
      expect(responderEndpoint.registeredContracts, contains('ParentService'));
      expect(responderEndpoint.registeredContracts, contains('SubService'));
      expect(responderEndpoint.registeredMethods,
          contains('ParentService.ParentMethod'));
      expect(responderEndpoint.registeredMethods,
          contains('SubService.SubUnaryMethod'));
    });

    test('Обработка унарного запроса работает корректно', () async {
      // Регистрируем сервис
      responderEndpoint.registerServiceContract(testService);

      // Отправляем запрос через caller
      final response =
          await callerEndpoint.unaryRequest<TestRequest, TestResponse>(
        serviceName: 'TestService',
        methodName: 'UnaryMethod',
        requestCodec: RpcCodec<TestRequest>(TestRequest.fromJson),
        responseCodec: RpcCodec<TestResponse>(TestResponse.fromJson),
        request: TestRequest('Test request'),
      );

      // Проверяем ответ и вызов обработчика
      expect(response.message, equals('Reply to: Test request'));
      expect(testService.callLog, contains('UnaryMethod: Test request'));
    });

    test('Ошибка при дублировании сервиса', () {
      // Регистрируем сервис первый раз
      responderEndpoint.registerServiceContract(testService);

      // Второй раз должна быть ошибка
      expect(
        () => responderEndpoint.registerServiceContract(TestService()),
        throwsA(isA<RpcException>()),
      );
    });

    test('Проверка существования метода', () {
      // Регистрируем сервис
      responderEndpoint.registerServiceContract(testService);

      // Проверяем существующий метод
      responderEndpoint.validateMethodExists(
          'TestService', 'UnaryMethod', RpcMethodType.unaryRequest);

      // Проверяем несуществующий метод
      expect(
        () => responderEndpoint.validateMethodExists(
            'TestService', 'NonExistentMethod', RpcMethodType.unaryRequest),
        throwsA(isA<RpcException>()),
      );

      // Проверяем метод с неверным типом
      expect(
        () => responderEndpoint.validateMethodExists(
            'TestService', 'UnaryMethod', RpcMethodType.serverStream),
        throwsA(isA<RpcException>()),
      );
    });

    test('Закрытие эндпоинта очищает зарегистрированные сервисы', () async {
      // Регистрируем сервис
      responderEndpoint.registerServiceContract(testService);
      expect(responderEndpoint.registeredContracts, isNotEmpty);
      expect(responderEndpoint.registeredMethods, isNotEmpty);

      // Закрываем эндпоинт
      await responderEndpoint.close();

      // Проверяем, что контракты и методы очищены
      expect(responderEndpoint.isActive, isFalse);
      expect(responderEndpoint.registeredContracts, isEmpty);
      expect(responderEndpoint.registeredMethods, isEmpty);
    });

    test('Обращение к методу через подконтракт работает корректно', () async {
      // Регистрируем сервис с подконтрактом
      final parentService = ParentService();
      responderEndpoint.registerServiceContract(parentService);

      // Отправляем запрос к методу подконтракта
      final response =
          await callerEndpoint.unaryRequest<TestRequest, TestResponse>(
        serviceName: 'SubService',
        methodName: 'SubUnaryMethod',
        requestCodec: RpcCodec<TestRequest>(TestRequest.fromJson),
        responseCodec: RpcCodec<TestResponse>(TestResponse.fromJson),
        request: TestRequest('Subcontract test'),
      );

      // Проверяем ответ и вызов обработчика
      expect(response.message, equals('SubService reply to: Subcontract test'));
      expect(parentService.subService.callLog,
          contains('SubUnaryMethod: Subcontract test'));
    });
  });
}
