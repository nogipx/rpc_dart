// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: LGPL-3.0-or-later

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

void main() {
  group('Валидация транспортов в эндпоинтах', () {
    late IRpcTransport clientTransport;
    late IRpcTransport serverTransport;

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
      // Правильное использование - клиентский транспорт
      expect(
        () => RpcCallerEndpoint(transport: clientTransport),
        returnsNormally,
      );

      // Ошибка - серверный транспорт в клиентском эндпоинте
      expect(
        () => RpcCallerEndpoint(transport: serverTransport),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('RpcResponderEndpoint принимает только серверный транспорт', () {
      // Правильное использование - серверный транспорт
      expect(
        () => RpcResponderEndpoint(transport: serverTransport),
        returnsNormally,
      );

      // Ошибка - клиентский транспорт в серверном эндпоинте
      expect(
        () => RpcResponderEndpoint(transport: clientTransport),
        throwsA(isA<ArgumentError>()),
      );
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
