// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: LGPL-3.0-or-later

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

void main() {
  group('Валидация транспортов в эндпоинтах', () {
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

    test('Проверяем роли транспортов', () {
      // Клиентский транспорт должен быть клиентским
      expect(clientTransport.isClient, isTrue);

      // Серверный транспорт должен быть серверным
      expect(serverTransport.isClient, isFalse);
    });

    test('RpcCallerEndpoint принимает только клиентский транспорт', () {
      // ✅ Правильное использование - клиентский транспорт
      expect(
        () => RpcCallerEndpoint(transport: clientTransport),
        returnsNormally,
      );

      // ❌ Ошибка - серверный транспорт в клиентском эндпоинте
      expect(
        () => RpcCallerEndpoint(transport: serverTransport),
        throwsA(isA<ArgumentError>().having(
          (e) => e.message,
          'message',
          contains(
              'КРИТИЧЕСКАЯ ОШИБКА: RpcCallerEndpoint требует КЛИЕНТСКИЙ транспорт'),
        )),
      );
    });

    test('RpcResponderEndpoint принимает только серверный транспорт', () {
      // ✅ Правильное использование - серверный транспорт
      expect(
        () => RpcResponderEndpoint(transport: serverTransport),
        returnsNormally,
      );

      // ❌ Ошибка - клиентский транспорт в серверном эндпоинте
      expect(
        () => RpcResponderEndpoint(transport: clientTransport),
        throwsA(isA<ArgumentError>().having(
          (e) => e.message,
          'message',
          contains(
              'КРИТИЧЕСКАЯ ОШИБКА: RpcResponderEndpoint требует СЕРВЕРНЫЙ транспорт'),
        )),
      );
    });

    test('Сообщения об ошибках содержат полезную информацию', () {
      try {
        RpcCallerEndpoint(transport: serverTransport);
        fail('Должна быть выброшена ошибка');
      } catch (e) {
        final message = e.toString();

        // Проверяем, что сообщение содержит полезную информацию
        expect(message,
            contains('RpcCallerEndpoint требует КЛИЕНТСКИЙ транспорт'));
        expect(message, contains('isClient: false'));
        expect(message, contains('нечетными Stream ID (1, 3, 5...)'));
        expect(message, contains('Правильное использование'));
        expect(message, contains('НЕПРАВИЛЬНО'));
      }

      try {
        RpcResponderEndpoint(transport: clientTransport);
        fail('Должна быть выброшена ошибка');
      } catch (e) {
        final message = e.toString();

        // Проверяем, что сообщение содержит полезную информацию
        expect(message,
            contains('RpcResponderEndpoint требует СЕРВЕРНЫЙ транспорт'));
        expect(message, contains('isClient: true'));
        expect(message, contains('четными Stream ID (2, 4, 6...)'));
        expect(message, contains('Правильное использование'));
        expect(message, contains('НЕПРАВИЛЬНО'));
      }
    });

    test('Stream ID генерируются правильно после валидации', () {
      final callerEndpoint = RpcCallerEndpoint(transport: clientTransport);
      final responderEndpoint =
          RpcResponderEndpoint(transport: serverTransport);

      // После создания эндпоинтов транспорты должны работать корректно
      expect(clientTransport.createStream(), equals(1)); // Нечетный
      expect(serverTransport.createStream(), equals(2)); // Четный
      expect(clientTransport.createStream(), equals(3)); // Нечетный
      expect(serverTransport.createStream(), equals(4)); // Четный

      // Закрываем эндпоинты
      callerEndpoint.close();
      responderEndpoint.close();
    });
  });
}
