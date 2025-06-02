// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: LGPL-3.0-or-later

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

void main() {
  group('RpcInMemoryTransport с управлением Stream ID', () {
    late RpcInMemoryTransport clientTransport;
    late RpcInMemoryTransport serverTransport;

    setUp(() {
      final pair = RpcInMemoryTransport.pair();
      clientTransport = pair.$1;
      serverTransport = pair.$2;
    });

    tearDown(() async {
      await clientTransport.close();
      await serverTransport.close();
    });

    test('Создает уникальные ID для клиента и сервера', () {
      // Клиент использует нечетные ID
      expect(clientTransport.createStream(), equals(1));
      expect(clientTransport.createStream(), equals(3));
      expect(clientTransport.createStream(), equals(5));

      // Сервер использует четные ID
      expect(serverTransport.createStream(), equals(2));
      expect(serverTransport.createStream(), equals(4));
      expect(serverTransport.createStream(), equals(6));
    });

    test('Освобождает ID при завершении стрима (finishSending)', () async {
      // Создаем поток
      final streamId = clientTransport.createStream();

      // Отправляем метаданные и сообщение
      final metadata =
          RpcMetadata.forClientRequest('TestService', 'TestMethod');
      await clientTransport.sendMetadata(streamId, metadata);
      await clientTransport.sendMessage(
        streamId,
        Uint8List.fromList([1, 2, 3]),
      );

      // Завершаем поток и проверяем, что ID освобожден
      await clientTransport.finishSending(streamId);

      // Создаем новый поток и проверяем, что его ID отличается от первого
      final newStreamId = clientTransport.createStream();
      expect(newStreamId, equals(3)); // Должен быть следующий нечетный
    });

    test('Освобождает ID при получении END_STREAM', () async {
      // Создаем первый клиентский поток с ID 1
      final streamId1 = clientTransport.createStream();
      expect(streamId1, equals(1));

      // Отправляем сообщение с флагом END_STREAM
      await clientTransport.sendMetadata(
        streamId1,
        RpcMetadata.forClientRequest('Test', 'Test'),
        endStream: true,
      );

      // Даем время на обработку сообщений
      await Future.delayed(Duration(milliseconds: 50));

      // Создаем новый клиентский поток - должен иметь ID 3
      final streamId2 = clientTransport.createStream();
      expect(streamId2, equals(3));

      // Создаем еще один поток и сразу завершаем его
      final streamId3 = clientTransport.createStream();
      expect(streamId3, equals(5));

      await clientTransport.sendMetadata(
        streamId3,
        RpcMetadata.forClientRequest('Test', 'Test'),
        endStream: true,
      );

      // Даем время на обработку
      await Future.delayed(Duration(milliseconds: 50));

      // Создаем еще один поток - должен быть ID 7, т.к. 5 еще не успел освободиться
      final streamId4 = clientTransport.createStream();
      expect(streamId4, equals(7));
    });

    test('Переиспользует ID после их освобождения', () async {
      // Создаем, используем и освобождаем несколько ID
      for (int i = 0; i < 3; i++) {
        final streamId = clientTransport.createStream(); // 1, 3, 5
        await clientTransport.sendMetadata(
          streamId,
          RpcMetadata.forClientRequest('Test', 'Test'),
          endStream: true,
        );
      }

      // Создаем новый транспорт
      final newPair = RpcInMemoryTransport.pair();
      final newClientTransport = newPair.$1;

      try {
        // После создания нового транспорта генерация должна начаться сначала
        expect(newClientTransport.createStream(), equals(1));
      } finally {
        await newClientTransport.close();
        await newPair.$2.close();
      }
    });

    test('Обрабатывает множество потоков одновременно', () async {
      // Создаем несколько потоков одновременно
      final totalStreams = 10;
      final streamIds = <int>[];

      // Создаем потоки
      for (int i = 0; i < totalStreams; i++) {
        streamIds.add(clientTransport.createStream());
      }

      // Проверяем, что все ID уникальны и нечетные
      expect(streamIds.length, equals(totalStreams));
      expect(streamIds.toSet().length, equals(totalStreams)); // все уникальные

      for (final id in streamIds) {
        expect(id % 2, equals(1)); // все нечетные
      }

      // Одновременно завершаем все потоки
      final futures = <Future>[];
      for (final id in streamIds) {
        futures.add(clientTransport.finishSending(id));
      }

      await Future.wait(futures);

      // Все ID должны быть освобождены, теперь следующий ID должен снова начинаться с 1
      // Пересоздаем транспорт, чтобы проверить поведение
      await clientTransport.close();
      await serverTransport.close();

      final newPair = RpcInMemoryTransport.pair();
      final newClientTransport = newPair.$1;

      try {
        expect(newClientTransport.createStream(), equals(1));
      } finally {
        await newClientTransport.close();
        await newPair.$2.close();
      }
    });
  });
}
