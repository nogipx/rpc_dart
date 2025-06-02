// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: LGPL-3.0-or-later

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

void main() {
  group('RpcStreamIdManager', () {
    test('Клиентский менеджер генерирует нечетные ID', () {
      final manager = RpcStreamIdManager(isClient: true);

      expect(manager.generateId(), equals(1));
      expect(manager.generateId(), equals(3));
      expect(manager.generateId(), equals(5));
      expect(manager.generateId(), equals(7));
      expect(manager.generateId(), equals(9));
    });

    test('Серверный менеджер генерирует четные ID', () {
      final manager = RpcStreamIdManager(isClient: false);

      expect(manager.generateId(), equals(2));
      expect(manager.generateId(), equals(4));
      expect(manager.generateId(), equals(6));
      expect(manager.generateId(), equals(8));
      expect(manager.generateId(), equals(10));
    });

    test('Успешно освобождает ID и отслеживает активные ID', () {
      final manager = RpcStreamIdManager(isClient: true);

      final id1 = manager.generateId(); // 1
      final id2 = manager.generateId(); // 3
      final id3 = manager.generateId(); // 5

      expect(manager.activeCount, equals(3));
      expect(manager.isActive(id1), isTrue);
      expect(manager.isActive(id2), isTrue);
      expect(manager.isActive(id3), isTrue);

      // Освобождаем id2
      expect(manager.releaseId(id2), isTrue);

      expect(manager.activeCount, equals(2));
      expect(manager.isActive(id1), isTrue);
      expect(manager.isActive(id2), isFalse);
      expect(manager.isActive(id3), isTrue);

      // Повторное освобождение должно вернуть false
      expect(manager.releaseId(id2), isFalse);

      // Освобождение неиспользуемого ID также должно вернуть false
      expect(manager.releaseId(999), isFalse);
    });

    test('Сброс менеджера очищает все активные ID', () {
      final manager = RpcStreamIdManager(isClient: true);

      // Генерируем несколько ID
      manager.generateId();
      manager.generateId();
      manager.generateId();

      expect(manager.activeCount, equals(3));

      // Сбрасываем
      manager.reset();

      expect(manager.activeCount, equals(0));

      // После сброса генерация должна начаться сначала
      expect(manager.generateId(), equals(1));
    });

    test('Имеет ограничение на максимальный ID', () {
      // Проверяем, что константа maxId имеет ожидаемое значение
      expect(RpcStreamIdManager.maxId, equals(0x7FFFFFFF));
      expect(RpcStreamIdManager.maxId, equals(2147483647));

      // Примечание: Реальный тест на переполнение ID невозможен,
      // так как потребовалось бы сгенерировать более миллиарда ID.
      // В реальных условиях приложение должно создавать новое соединение
      // при достижении этого ограничения.
    });
  });

  group('Интеграция с транспортом', () {
    test('RpcInMemoryTransport корректно генерирует и освобождает ID', () {
      final (clientTransport, serverTransport) = RpcInMemoryTransport.pair();

      // Проверяем генерацию ID в клиентском транспорте
      final clientId1 = clientTransport.createStream(); // должен быть 1
      final clientId2 = clientTransport.createStream(); // должен быть 3

      expect(clientId1, equals(1));
      expect(clientId2, equals(3));

      // Проверяем генерацию ID в серверном транспорте
      final serverId1 = serverTransport.createStream(); // должен быть 2
      final serverId2 = serverTransport.createStream(); // должен быть 4

      expect(serverId1, equals(2));
      expect(serverId2, equals(4));

      // Проверяем освобождение ID
      expect(clientTransport.releaseStreamId(clientId1), isTrue);
      expect(serverTransport.releaseStreamId(serverId1), isTrue);

      // Повторное освобождение должно вернуть false
      expect(clientTransport.releaseStreamId(clientId1), isFalse);
      expect(serverTransport.releaseStreamId(serverId1), isFalse);
    });
  });
}
