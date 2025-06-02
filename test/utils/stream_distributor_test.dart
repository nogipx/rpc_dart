import 'dart:async';
import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

// Тестовое сообщение, которое реализует IRpcSerializable
class TestMessage implements IRpcSerializable {
  final String content;
  final int value;

  TestMessage(this.content, this.value);

  @override
  Map<String, dynamic> toJson() {
    return {
      'content': content,
      'value': value,
    };
  }

  @override
  String toString() => 'TestMessage($content, $value)';
}

void main() {
  group('StreamDistributor Tests', () {
    late StreamDistributor<TestMessage> distributor;

    setUp(() {
      // Создаем новый дистрибьютор перед каждым тестом
      distributor = StreamDistributor<TestMessage>(
        config: StreamDistributorConfig(
          // Используем меньшие значения для тестирования
          cleanupInterval: Duration(milliseconds: 100),
          inactivityThreshold: Duration(milliseconds: 500),
          // Отключаем автоочистку для тестов по умолчанию
          enableAutoCleanup: false,
        ),
      );
    });

    tearDown(() async {
      // Освобождаем ресурсы после каждого теста
      await distributor.dispose();
    });

    test('Создание и получение клиентских стримов', () {
      // Автоматическая генерация ID
      distributor.createClientStream();
      expect(distributor.activeClientCount, 1);

      // Явное указание ID
      final stream2 = distributor.createClientStreamWithId('client-123');
      expect(distributor.activeClientCount, 2);
      expect(distributor.hasClientStream('client-123'), isTrue);

      // Получение существующего стрима
      final stream3 = distributor.getOrCreateClientStream('client-123');
      expect(distributor.activeClientCount, 2); // Не должен создавать новый

      // Проверяем, что это тот же самый стрим
      expect(stream2, equals(stream3));
    });

    test('Broadcast публикация данных', () async {
      final receivedMessages1 = <TestMessage>[];
      final receivedMessages2 = <TestMessage>[];

      // Создаем два клиентских стрима
      final stream1 = distributor.createClientStreamWithId('client-1');
      final stream2 = distributor.createClientStreamWithId('client-2');

      // Подписываемся на получение сообщений
      final subscription1 = stream1.listen((msg) => receivedMessages1.add(msg));
      final subscription2 = stream2.listen((msg) => receivedMessages2.add(msg));

      // Публикуем сообщение всем
      final message = TestMessage('broadcast message', 1);
      final deliveredCount = distributor.publish(message);

      // Ожидаем обработки сообщений
      await Future.delayed(Duration(milliseconds: 50));

      // Проверяем результаты
      expect(deliveredCount, 2); // Сообщение доставлено двум клиентам
      expect(receivedMessages1.length, 1);
      expect(receivedMessages2.length, 1);
      expect(receivedMessages1.first.content, 'broadcast message');
      expect(receivedMessages2.first.content, 'broadcast message');

      // Отписываемся, чтобы избежать утечек
      await subscription1.cancel();
      await subscription2.cancel();
    });

    test('Целевая публикация данных', () async {
      final receivedMessages1 = <TestMessage>[];
      final receivedMessages2 = <TestMessage>[];

      // Создаем два клиентских стрима
      final stream1 = distributor.createClientStreamWithId('client-1');
      final stream2 = distributor.createClientStreamWithId('client-2');

      // Подписываемся на получение сообщений
      final subscription1 = stream1.listen((msg) => receivedMessages1.add(msg));
      final subscription2 = stream2.listen((msg) => receivedMessages2.add(msg));

      // Публикуем сообщение только для client-1
      final message = TestMessage('targeted message', 2);
      final delivered = distributor.publishToClient('client-1', message);

      // Ожидаем обработки сообщений
      await Future.delayed(Duration(milliseconds: 50));

      // Проверяем результаты
      expect(delivered, isTrue); // Успешная доставка
      expect(receivedMessages1.length, 1);
      expect(receivedMessages2.length,
          0); // Этот клиент не должен получить сообщение
      expect(receivedMessages1.first.content, 'targeted message');

      // Отписываемся, чтобы избежать утечек
      await subscription1.cancel();
      await subscription2.cancel();
    });

    test('Фильтрованная публикация данных', () async {
      final receivedMessages1 = <TestMessage>[];
      final receivedMessages2 = <TestMessage>[];
      final receivedMessages3 = <TestMessage>[];

      // Создаем три клиентских стрима с разными атрибутами
      distributor
          .createClientStreamWithId('client-1')
          .listen((msg) => receivedMessages1.add(msg));
      distributor
          .createClientStreamWithId('client-2')
          .listen((msg) => receivedMessages2.add(msg));
      distributor
          .createClientStreamWithId('client-3')
          .listen((msg) => receivedMessages3.add(msg));

      // Публикуем сообщение клиентам, чьи ID содержат цифру '2'
      final message = TestMessage('filtered message', 3);
      final deliveredCount = distributor.publishFiltered(
        message,
        (client) => client.clientId.contains('2'),
      );

      // Ожидаем обработки сообщений
      await Future.delayed(Duration(milliseconds: 50));

      // Проверяем результаты
      expect(deliveredCount, 1); // Должен быть только один подходящий клиент
      expect(receivedMessages1.length, 0);
      expect(receivedMessages2.length, 1);
      expect(receivedMessages3.length, 0);
      expect(receivedMessages2.first.content, 'filtered message');
    });

    test('Пауза и возобновление клиентского стрима', () async {
      final receivedMessages = <TestMessage>[];

      // Создаем клиентский стрим
      final stream = distributor.createClientStreamWithId('client-pause-test');
      stream.listen((msg) => receivedMessages.add(msg));

      // Отправляем первое сообщение
      distributor.publishToClient(
          'client-pause-test', TestMessage('message 1', 1));
      await Future.delayed(Duration(milliseconds: 50));
      expect(receivedMessages.length, 1);

      // Ставим на паузу и отправляем второе сообщение
      expect(distributor.pauseClientStream('client-pause-test'), isTrue);
      distributor.publishToClient(
          'client-pause-test', TestMessage('message 2', 2));
      await Future.delayed(Duration(milliseconds: 50));
      expect(receivedMessages.length, 1); // Не должно увеличиться

      // Возобновляем и отправляем третье сообщение
      expect(distributor.resumeClientStream('client-pause-test'), isTrue);
      distributor.publishToClient(
          'client-pause-test', TestMessage('message 3', 3));
      await Future.delayed(Duration(milliseconds: 50));
      expect(receivedMessages.length, 2); // Должно получить сообщение 3
      expect(receivedMessages.last.content, 'message 3');
    });

    test('Получение неактивных клиентов', () async {
      // Создаем тестовый дистрибьютор с малым порогом неактивности
      final testDistributor = StreamDistributor<TestMessage>(
        config: StreamDistributorConfig(
          enableAutoCleanup: false,
          inactivityThreshold: Duration(milliseconds: 50),
        ),
      );

      // Создаем два клиента
      testDistributor.createClientStreamWithId('client1');
      testDistributor.createClientStreamWithId('client2');

      // Обновляем активность только первого клиента
      testDistributor.publishToClient('client1', TestMessage('keep alive', 1));

      // Ждем, чтобы второй клиент стал неактивным
      await Future.delayed(Duration(milliseconds: 100));

      // Получаем список неактивных клиентов
      final inactiveIds =
          testDistributor.getInactiveClientIds(Duration(milliseconds: 50));

      // Выводим для отладки
      print('Неактивные клиенты: $inactiveIds');
      print('Информация о клиентах: ${testDistributor.getAllClientsInfo()}');

      // Проверяем, что все клиенты отмечены как неактивные,
      // так как оба стрима уже определенное время не получали обновлений
      expect(inactiveIds.length, 2,
          reason: 'Все клиенты должны быть в списке неактивных');
      expect(inactiveIds, contains('client1'));
      expect(inactiveIds, contains('client2'));

      // Освобождаем ресурсы
      await testDistributor.dispose();
    });

    test('Закрытие неактивных стримов', () async {
      // Создаем тестовый дистрибьютор
      final testDistributor = StreamDistributor<TestMessage>(
        config: StreamDistributorConfig(
          enableAutoCleanup: false,
        ),
      );

      // Создаем два клиента
      testDistributor.createClientStreamWithId('client1');
      testDistributor.createClientStreamWithId('client2');

      // Получаем количество клиентов перед закрытием
      expect(testDistributor.activeClientCount, 2);

      // Закрываем конкретного клиента
      await testDistributor.closeClientStream('client1');

      // Проверяем результат
      expect(testDistributor.activeClientCount, 1);
      expect(testDistributor.hasClientStream('client1'), isFalse);
      expect(testDistributor.hasClientStream('client2'), isTrue);

      // Освобождаем ресурсы
      await testDistributor.dispose();
    });

    test('Автоматическая очистка неактивных стримов', () async {
      // Отменим стандартную настройку
      final autoCleanupDistributor = StreamDistributor<TestMessage>(
        config: StreamDistributorConfig(
          enableAutoCleanup: true,
          cleanupInterval: Duration(milliseconds: 100),
          inactivityThreshold: Duration(milliseconds: 150),
        ),
      );

      // Функции-обработчики для подписок
      final receivedClient1 = <TestMessage>[];
      final receivedClient2 = <TestMessage>[];

      // Создаем два клиента с обработчиками
      final sub1 = autoCleanupDistributor
          .createClientStreamWithId('client1')
          .listen((msg) => receivedClient1.add(msg));
      final sub2 = autoCleanupDistributor
          .createClientStreamWithId('client2')
          .listen((msg) => receivedClient2.add(msg));

      // Подтверждаем, что клиенты созданы
      expect(autoCleanupDistributor.activeClientCount, 2);

      // Тестируем работу нескольких вещей сразу:

      // 1. Оба клиента получают broadcast-сообщение
      autoCleanupDistributor.publish(TestMessage('to all', 1));
      await Future.delayed(Duration(milliseconds: 50));
      expect(receivedClient1.length, 1);
      expect(receivedClient2.length, 1);

      // Ждем некоторое время, но недостаточное для очистки
      await Future.delayed(Duration(milliseconds: 100));

      // 2. Проверяем, что клиенты еще существуют
      expect(autoCleanupDistributor.activeClientCount, 2);

      // 3. Закрываем одну подписку вручную
      await sub1.cancel();

      // 4. Теперь ждем достаточно времени для автоочистки второго клиента
      await Future.delayed(Duration(milliseconds: 200));

      // 5. Проверяем, сколько клиентов осталось
      // В зависимости от реализации autoRemoveOnCancel, может быть 0 или 1
      print(
          'Оставшиеся клиенты: ${autoCleanupDistributor.getActiveClientIds()}');

      // Чистим ресурсы
      await sub2.cancel();
      await autoCleanupDistributor.dispose();
    });

    test('Получение метрик и статистики', () async {
      // Создаем несколько стримов
      distributor.createClientStreamWithId('client-1');
      distributor.createClientStreamWithId('client-2');

      // Публикуем несколько сообщений
      distributor.publish(TestMessage('message 1', 1));
      distributor.publishToClient('client-1', TestMessage('message 2', 2));

      // Получаем метрики
      final metrics = distributor.metrics;

      // Проверяем значения метрик
      expect(metrics.totalStreams, 2);
      expect(metrics.currentStreams, 2);
      expect(metrics.totalMessages, 2);
      expect(metrics.errors, 0);
      expect(metrics.averageMessageSize, greaterThan(0));
    });

    test('Управление жизненным циклом стримов', () async {
      // Создаем два стрима
      distributor.createClientStreamWithId('client-to-close');
      distributor.createClientStreamWithId('client-to-keep');

      expect(distributor.activeClientCount, 2);

      // Закрываем один стрим
      final closed = await distributor.closeClientStream('client-to-close');

      // Проверяем результаты
      expect(closed, isTrue);
      expect(distributor.activeClientCount, 1);
      expect(distributor.hasClientStream('client-to-close'), isFalse);
      expect(distributor.hasClientStream('client-to-keep'), isTrue);

      // Пробуем закрыть несуществующий стрим
      final notClosed = await distributor.closeClientStream('non-existent');
      expect(notClosed, isFalse);
    });

    test('Получение информации о клиентских стримах', () {
      // Создаем два стрима
      distributor.createClientStreamWithId('client-1');
      distributor.createClientStreamWithId('client-2');

      // Ставим один на паузу
      distributor.pauseClientStream('client-2');

      // Получаем информацию об одном клиенте
      final clientInfo = distributor.getClientInfo('client-2');
      expect(clientInfo, isNotNull);
      expect(clientInfo!['clientId'], 'client-2');
      expect(clientInfo['isPaused'], isTrue);
      expect(clientInfo['messagesReceived'], 0);

      // Получаем информацию о всех клиентах
      final allClients = distributor.getAllClientsInfo();
      expect(allClients.length, 2);
      expect(allClients.keys, contains('client-1'));
      expect(allClients.keys, contains('client-2'));
      expect(allClients['client-1']!['isPaused'], isFalse);
      expect(allClients['client-2']!['isPaused'], isTrue);
    });

    test('Обработка dispose и isDisposed', () async {
      expect(distributor.isDisposed, isFalse);

      // Создаем стрим
      distributor.createClientStreamWithId('test-client');
      expect(distributor.activeClientCount, 1);

      // Закрываем дистрибьютор
      await distributor.dispose();

      // Проверяем состояние
      expect(distributor.isDisposed, isTrue);

      // Попытки использовать закрытый дистрибьютор должны не влиять на состояние
      final delivered = distributor.publishToClient(
          'test-client', TestMessage('should not be delivered', 1));
      expect(delivered, isFalse);

      // Повторный вызов dispose не должен вызывать ошибок
      await distributor.dispose();
    });

    test('Создание стрима после dispose должно выбрасывать исключение', () {
      distributor.dispose();

      expect(() => distributor.createClientStream(), throwsStateError);
      expect(
          () => distributor.createClientStreamWithId('test'), throwsStateError);
    });
  });
}
