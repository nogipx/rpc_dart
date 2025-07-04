// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

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
          await Future.delayed(Duration(milliseconds: 1));
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
      handler: (request, {context}) async {
        callLog.add('SubUnaryMethod: ${request.message}');
        return TestResponse('SubService reply to: ${request.message}');
      },
      requestCodec: RpcCodec<TestRequest>(TestRequest.fromJson),
      responseCodec: RpcCodec<TestResponse>(TestResponse.fromJson),
    );
  }
}

/// Тестовый родительский контракт
final class ParentService extends RpcResponderContract {
  final List<String> callLog = [];

  ParentService() : super('ParentService');

  @override
  void setup() {
    addUnaryMethod<TestRequest, TestResponse>(
      methodName: 'ParentMethod',
      handler: (request, {context}) async {
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
      responderEndpoint.start();

      // Проверяем, что сервис был зарегистрирован
      expect(responderEndpoint.registeredContracts, contains('TestService'));
      expect(responderEndpoint.registeredMethods,
          contains('TestService.UnaryMethod'));
      expect(responderEndpoint.registeredMethods,
          contains('TestService.ServerStreamMethod'));
    });

    test('Регистрация нескольких контрактов работает корректно', () {
      // Создаем и регистрируем несколько сервисов отдельно
      final parentService = ParentService();
      final subService = SubService();
      responderEndpoint.registerServiceContract(parentService);
      responderEndpoint.registerServiceContract(subService);
      responderEndpoint.start();

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
      responderEndpoint.start();

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
      responderEndpoint.start();

      // Второй раз должна быть ошибка
      expect(
        () => responderEndpoint.registerServiceContract(TestService()),
        throwsA(isA<RpcException>()),
      );
    });

    test('Проверка существования метода', () {
      // Регистрируем сервис
      responderEndpoint.registerServiceContract(testService);
      responderEndpoint.start();

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
      responderEndpoint.start();
      expect(responderEndpoint.registeredContracts, isNotEmpty);
      expect(responderEndpoint.registeredMethods, isNotEmpty);

      // Закрываем эндпоинт
      await responderEndpoint.close();

      // Проверяем, что контракты и методы очищены
      expect(responderEndpoint.isActive, isFalse);
      expect(responderEndpoint.registeredContracts, isEmpty);
      expect(responderEndpoint.registeredMethods, isEmpty);
    });

    test('Обращение к отдельно зарегистрированному сервису работает корректно',
        () async {
      // Регистрируем оба сервиса отдельно
      final parentService = ParentService();
      final subService = SubService();
      responderEndpoint.registerServiceContract(parentService);
      responderEndpoint.registerServiceContract(subService);
      responderEndpoint.start();

      // Отправляем запрос к методу SubService
      final response =
          await callerEndpoint.unaryRequest<TestRequest, TestResponse>(
        serviceName: 'SubService',
        methodName: 'SubUnaryMethod',
        requestCodec: RpcCodec<TestRequest>(TestRequest.fromJson),
        responseCodec: RpcCodec<TestResponse>(TestResponse.fromJson),
        request: TestRequest('SubService test'),
      );

      // Проверяем ответ и вызов обработчика
      expect(response.message, equals('SubService reply to: SubService test'));
      expect(subService.callLog, contains('SubUnaryMethod: SubService test'));
    });

    test('Регистрация без запуска работает корректно', () {
      // Регистрируем сервис но НЕ запускаем эндпоинт
      responderEndpoint.registerServiceContract(testService);

      // Проверяем что сервис зарегистрирован
      expect(responderEndpoint.registeredContracts, contains('TestService'));

      // Проверяем что эндпоинт активен но не слушает
      expect(responderEndpoint.isActive, isTrue);

      // Примечание: Предупреждение о незапущенном эндпоинте появится
      // только при получении реального сообщения от транспорта
    });

    group('unregisterServiceContract тесты', () {
      test('Разрегистрация зарегистрированного сервиса работает корректно', () {
        // Регистрируем сервис
        responderEndpoint.registerServiceContract(testService);
        responderEndpoint.start();

        // Проверяем что сервис зарегистрирован
        expect(responderEndpoint.registeredContracts, contains('TestService'));
        expect(responderEndpoint.registeredMethods,
            contains('TestService.UnaryMethod'));
        expect(responderEndpoint.registeredMethods,
            contains('TestService.ServerStreamMethod'));

        // Разрегистрируем сервис
        responderEndpoint.unregisterServiceContract('TestService');

        // Проверяем что сервис и его методы удалены
        expect(responderEndpoint.registeredContracts,
            isNot(contains('TestService')));
        expect(responderEndpoint.registeredMethods,
            isNot(contains('TestService.UnaryMethod')));
        expect(responderEndpoint.registeredMethods,
            isNot(contains('TestService.ServerStreamMethod')));
      });

      test('Разрегистрация одного сервиса не влияет на другие', () {
        // Регистрируем несколько сервисов
        final parentService = ParentService();
        final subService = SubService();
        responderEndpoint.registerServiceContract(testService);
        responderEndpoint.registerServiceContract(parentService);
        responderEndpoint.registerServiceContract(subService);
        responderEndpoint.start();

        // Проверяем что все сервисы зарегистрированы
        expect(responderEndpoint.registeredContracts, contains('TestService'));
        expect(
            responderEndpoint.registeredContracts, contains('ParentService'));
        expect(responderEndpoint.registeredContracts, contains('SubService'));

        // Разрегистрируем только один сервис
        responderEndpoint.unregisterServiceContract('ParentService');

        // Проверяем что только ParentService удален
        expect(responderEndpoint.registeredContracts, contains('TestService'));
        expect(responderEndpoint.registeredContracts,
            isNot(contains('ParentService')));
        expect(responderEndpoint.registeredContracts, contains('SubService'));

        // Проверяем что методы других сервисов остались
        expect(responderEndpoint.registeredMethods,
            contains('TestService.UnaryMethod'));
        expect(responderEndpoint.registeredMethods,
            contains('SubService.SubUnaryMethod'));
        expect(responderEndpoint.registeredMethods,
            isNot(contains('ParentService.ParentMethod')));
      });

      test('Ошибка при разрегистрации незарегистрированного сервиса', () {
        // Пытаемся разрегистрировать несуществующий сервис
        expect(
          () =>
              responderEndpoint.unregisterServiceContract('NonExistentService'),
          throwsA(isA<RpcException>()),
        );
      });

      test('Разрегистрация сервиса позволяет повторную регистрацию', () {
        // Регистрируем сервис
        responderEndpoint.registerServiceContract(testService);
        responderEndpoint.start();

        // Проверяем что сервис зарегистрирован
        expect(responderEndpoint.registeredContracts, contains('TestService'));

        // Разрегистрируем сервис
        responderEndpoint.unregisterServiceContract('TestService');

        // Проверяем что сервис удален
        expect(responderEndpoint.registeredContracts,
            isNot(contains('TestService')));

        // Регистрируем новый экземпляр того же сервиса
        final newTestService = TestService();
        responderEndpoint.registerServiceContract(newTestService);

        // Проверяем что сервис снова зарегистрирован
        expect(responderEndpoint.registeredContracts, contains('TestService'));
        expect(responderEndpoint.registeredMethods,
            contains('TestService.UnaryMethod'));
      });

      test('Функциональность эндпоинта работает после разрегистрации',
          () async {
        // Регистрируем несколько сервисов
        final parentService = ParentService();
        responderEndpoint.registerServiceContract(testService);
        responderEndpoint.registerServiceContract(parentService);
        responderEndpoint.start();

        // Разрегистрируем один сервис
        responderEndpoint.unregisterServiceContract('TestService');

        // Проверяем что оставшийся сервис все еще работает
        final response =
            await callerEndpoint.unaryRequest<TestRequest, TestResponse>(
          serviceName: 'ParentService',
          methodName: 'ParentMethod',
          requestCodec: RpcCodec<TestRequest>(TestRequest.fromJson),
          responseCodec: RpcCodec<TestResponse>(TestResponse.fromJson),
          request: TestRequest('After unregister test'),
        );

        expect(response.message,
            equals('ParentService reply to: After unregister test'));
        expect(parentService.callLog,
            contains('ParentMethod: After unregister test'));
      });

      test('Разрегистрация всех сервисов очищает все методы', () {
        // Регистрируем несколько сервисов
        final parentService = ParentService();
        final subService = SubService();
        responderEndpoint.registerServiceContract(testService);
        responderEndpoint.registerServiceContract(parentService);
        responderEndpoint.registerServiceContract(subService);
        responderEndpoint.start();

        // Проверяем что все сервисы и методы зарегистрированы
        expect(responderEndpoint.registeredContracts, hasLength(3));
        expect(responderEndpoint.registeredMethods, isNotEmpty);

        // Разрегистрируем все сервисы по очереди
        responderEndpoint.unregisterServiceContract('TestService');
        responderEndpoint.unregisterServiceContract('ParentService');
        responderEndpoint.unregisterServiceContract('SubService');

        // Проверяем что все контракты и методы удалены
        expect(responderEndpoint.registeredContracts, isEmpty);
        expect(responderEndpoint.registeredMethods, isEmpty);
      });

      test('Регистрация и разрегистрация работает после start()', () async {
        // Стартуем эндпоинт без сервисов
        responderEndpoint.start();

        // Регистрируем сервис ПОСЛЕ start()
        responderEndpoint.registerServiceContract(testService);

        // Проверяем что сервис зарегистрирован и работает
        expect(responderEndpoint.registeredContracts, contains('TestService'));

        final response =
            await callerEndpoint.unaryRequest<TestRequest, TestResponse>(
          serviceName: 'TestService',
          methodName: 'UnaryMethod',
          requestCodec: RpcCodec<TestRequest>(TestRequest.fromJson),
          responseCodec: RpcCodec<TestResponse>(TestResponse.fromJson),
          request: TestRequest('After start test'),
        );

        expect(response.message, equals('Reply to: After start test'));
        expect(testService.callLog, contains('UnaryMethod: After start test'));

        // Разрегистрируем сервис ПОСЛЕ start()
        responderEndpoint.unregisterServiceContract('TestService');

        // Проверяем что сервис удален
        expect(responderEndpoint.registeredContracts,
            isNot(contains('TestService')));

        // Регистрируем новый сервис ПОСЛЕ разрегистрации
        final newService = TestService();
        responderEndpoint.registerServiceContract(newService);

        // Проверяем что новый сервис работает
        final newResponse =
            await callerEndpoint.unaryRequest<TestRequest, TestResponse>(
          serviceName: 'TestService',
          methodName: 'UnaryMethod',
          requestCodec: RpcCodec<TestRequest>(TestRequest.fromJson),
          responseCodec: RpcCodec<TestResponse>(TestResponse.fromJson),
          request: TestRequest('New service test'),
        );

        expect(newResponse.message, equals('Reply to: New service test'));
        expect(newService.callLog, contains('UnaryMethod: New service test'));
        // Убеждаемся что старый сервис не получил запрос
        expect(testService.callLog,
            isNot(contains('UnaryMethod: New service test')));
      });

      test('Ресурсы автоматически освобождаются при разрегистрации', () async {
        // Создаем тестовый респондер с типичными ресурсами
        final resourceService = ResourceHeavyService();
        responderEndpoint.registerServiceContract(resourceService);
        responderEndpoint.start();

        // Проверяем что сервис зарегистрирован
        expect(responderEndpoint.registeredContracts,
            contains('ResourceHeavyService'));

        // Вызываем метод который может создать ресурсы
        final response =
            await callerEndpoint.unaryRequest<TestRequest, TestResponse>(
          serviceName: 'ResourceHeavyService',
          methodName: 'CreateResourceIntensiveOperation',
          requestCodec: RpcCodec<TestRequest>(TestRequest.fromJson),
          responseCodec: RpcCodec<TestResponse>(TestResponse.fromJson),
          request: TestRequest('setup resources'),
        );

        expect(response.message, contains('resources created'));
        expect(resourceService.isResourcesActive(), isTrue);

        // Разрегистрируем сервис - теперь dispose() вызывается автоматически!
        responderEndpoint.unregisterServiceContract('ResourceHeavyService');

        // ✅ С новой dispose() интеграцией ресурсы автоматически освобождаются
        expect(resourceService.isResourcesActive(), isFalse);
        expect(resourceService.activeConnections, equals(0));
      });

      test('dispose() автоматически вызывается при unregisterServiceContract()',
          () async {
        // Создаем тестовый респондер с ресурсами
        final resourceService = ResourceHeavyService();
        responderEndpoint.registerServiceContract(resourceService);
        responderEndpoint.start();

        // Создаем ресурсы
        final response =
            await callerEndpoint.unaryRequest<TestRequest, TestResponse>(
          serviceName: 'ResourceHeavyService',
          methodName: 'CreateResourceIntensiveOperation',
          requestCodec: RpcCodec<TestRequest>(TestRequest.fromJson),
          responseCodec: RpcCodec<TestResponse>(TestResponse.fromJson),
          request: TestRequest('setup resources'),
        );

        expect(response.message, contains('resources created'));
        expect(resourceService.isResourcesActive(), isTrue);

        // 🆕 Разрегистрируем сервис - dispose() должен вызваться автоматически
        responderEndpoint.unregisterServiceContract('ResourceHeavyService');

        // ✅ Ресурсы должны быть автоматически освобождены
        expect(resourceService.isResourcesActive(), isFalse);
        expect(resourceService.activeConnections, equals(0));
      });

      test('dispose() автоматически вызывается при close() эндпоинта',
          () async {
        // Создаем новый эндпоинт для этого теста
        final (newCallerTransport, newResponderTransport) =
            RpcInMemoryTransport.pair();
        final newResponderEndpoint =
            RpcResponderEndpoint(transport: newResponderTransport);
        final newCallerEndpoint =
            RpcCallerEndpoint(transport: newCallerTransport);

        // Регистрируем сервис с ресурсами
        final resourceService1 = ResourceHeavyService();

        newResponderEndpoint.registerServiceContract(resourceService1);
        newResponderEndpoint.start();

        // Создаем ресурсы в обоих сервисах
        await newCallerEndpoint.unaryRequest<TestRequest, TestResponse>(
          serviceName: 'ResourceHeavyService',
          methodName: 'CreateResourceIntensiveOperation',
          requestCodec: RpcCodec<TestRequest>(TestRequest.fromJson),
          responseCodec: RpcCodec<TestResponse>(TestResponse.fromJson),
          request: TestRequest('setup resources 1'),
        );

        expect(resourceService1.isResourcesActive(), isTrue);

        // 🆕 Закрываем эндпоинт - dispose() должен вызваться для всех контрактов
        await newResponderEndpoint.close();

        // ✅ Ресурсы всех сервисов должны быть освобождены
        expect(resourceService1.isResourcesActive(), isFalse);
        expect(resourceService1.activeConnections, equals(0));

        // Очистка
        await newCallerEndpoint.close();
      });

      test('dispose() обрабатывает ошибки gracefully', () async {
        // Создаем сервис который выбрасывает ошибку в dispose()
        final problematicService = ProblematicDisposeService();
        responderEndpoint.registerServiceContract(problematicService);
        responderEndpoint.start();

        // Разрегистрируем сервис - не должно упасть с ошибкой
        expect(
            () => responderEndpoint
                .unregisterServiceContract('ProblematicDisposeService'),
            returnsNormally);

        // Проверяем что сервис все равно удален
        expect(responderEndpoint.registeredContracts,
            isNot(contains('ProblematicDisposeService')));
      });
    });
  });
}

/// Тестовый сервис имитирующий реальные ресурсы которые нужно освобождать
final class ResourceHeavyService extends RpcResponderContract {
  final List<StreamController> _activeStreams = [];
  final Map<String, StreamSubscription> _subscriptions = {};
  final List<Timer> _timers = [];
  int activeConnections = 0;
  bool _resourcesActive = false;

  ResourceHeavyService() : super('ResourceHeavyService');

  @override
  void setup() {
    addUnaryMethod<TestRequest, TestResponse>(
      methodName: 'CreateResourceIntensiveOperation',
      handler: (request, {context}) async {
        // Имитируем создание ресурсов
        _createFakeResources();
        return TestResponse(
            'resources created - connections: $activeConnections');
      },
      requestCodec: RpcCodec<TestRequest>(TestRequest.fromJson),
      responseCodec: RpcCodec<TestResponse>(TestResponse.fromJson),
    );
  }

  void _createFakeResources() {
    // 1. Создаем несколько потоков данных
    for (int i = 0; i < 3; i++) {
      final controller = StreamController<String>.broadcast();
      _activeStreams.add(controller);

      // Имитируем подписку на внешний поток
      final subscription =
          Stream.periodic(Duration(seconds: 1), (count) => 'data_$count')
              .listen(controller.add);
      _subscriptions['stream_$i'] = subscription;
    }

    // 2. Создаем таймеры
    for (int i = 0; i < 2; i++) {
      final timer = Timer.periodic(Duration(seconds: 2), (timer) {
        activeConnections++;
      });
      _timers.add(timer);
    }

    // 3. Имитируем открытие подключений к БД/сервисам
    activeConnections = 5;
    _resourcesActive = true;
  }

  bool isResourcesActive() => _resourcesActive;

  /// 🆕 Переопределяем dispose() для автоматической очистки ресурсов
  @override
  void dispose() {
    // Закрываем потоки
    for (final controller in _activeStreams) {
      controller.close();
    }
    _activeStreams.clear();

    // Отменяем подписки
    for (final subscription in _subscriptions.values) {
      subscription.cancel();
    }
    _subscriptions.clear();

    // Отменяем таймеры
    for (final timer in _timers) {
      timer.cancel();
    }
    _timers.clear();

    // Закрываем подключения
    activeConnections = 0;
    _resourcesActive = false;

    // Вызываем родительский dispose
    super.dispose();
  }

  /// Ручная очистка ресурсов (для тестов совместимости)
  void manualCleanup() {
    dispose();
  }
}

/// Тестовый сервис который выбрасывает ошибку в dispose() для тестирования error handling
final class ProblematicDisposeService extends RpcResponderContract {
  ProblematicDisposeService() : super('ProblematicDisposeService');

  @override
  void setup() {
    addUnaryMethod<TestRequest, TestResponse>(
      methodName: 'TestMethod',
      handler: (request, {context}) async {
        return TestResponse('test response');
      },
      requestCodec: RpcCodec<TestRequest>(TestRequest.fromJson),
      responseCodec: RpcCodec<TestResponse>(TestResponse.fromJson),
    );
  }

  @override
  void dispose() {
    // Симулируем ошибку в dispose()
    throw Exception('Ошибка при освобождении ресурсов');
  }
}
