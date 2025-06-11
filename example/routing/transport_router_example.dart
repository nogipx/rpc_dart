// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: LGPL-3.0-or-later

import 'dart:async';
import 'package:rpc_dart/rpc_dart.dart';

void main() async {
  print('🚌 Transport Router Factory Constructor Example');
  print('=' * 50);

  // 1. Создаем пары транспортов
  final userPair = RpcInMemoryTransport.pair();
  final userClientTransport = userPair.$1;
  final userServerTransport = userPair.$2;

  final paymentPair = RpcInMemoryTransport.pair();
  final paymentClientTransport = paymentPair.$1;
  final paymentServerTransport = paymentPair.$2;

  print('✅ Создали пары транспортов');

  // 2. Создаем клиентский Router с factory constructor
  print('\n📝 Создаем клиентский Router...');
  final clientRouter = RpcTransportRouterBuilder.client()
      .routeCall(
          calledServiceName: 'UserService',
          toTransport: userClientTransport,
          priority: 100)
      .routeCall(
          calledServiceName: 'PaymentService',
          toTransport: userClientTransport,
          priority: 90)
      .build();

  print('✅ Клиентский Router создан!');
  print(
      '   Stream ID для клиента: ${clientRouter.createStream()} (должен быть нечетным)');

  // 3. Создаем серверный Router
  print('\n📝 Создаем серверный Router...');
  final serverRouter = RpcTransportRouterBuilder.client()
      .routeCall(
          calledServiceName: 'UserService',
          toTransport: userClientTransport,
          priority: 100)
      .routeCall(
          calledServiceName: 'PaymentService',
          toTransport: paymentClientTransport,
          priority: 90)
      .build();

  print('✅ Серверный Router создан!');
  print(
      '   Stream ID для сервера: ${serverRouter.createStream()} (должен быть четным)');

  // 4. Тестируем отправку сообщений
  print('\n📤 Тестируем отправку сообщений...');

  // Слушаем входящие сообщения на серверной стороне
  final receivedMessages = <RpcTransportMessage>[];
  userClientTransport.incomingMessages.listen((message) {
    receivedMessages.add(message);
    print(
        '   📨 Получено сообщение: service=${message.metadata?.getHeaderValue('x-route-service')}');
  });

  // Отправляем запрос через клиентский router
  final streamId = clientRouter.createStream();

  await clientRouter.sendMetadata(
      streamId,
      RpcMetadata([
        RpcHeader('x-route-service', 'UserService'),
        RpcHeader('x-method', 'getUser'),
      ]));

  await clientRouter.sendMessage(
      streamId, Uint8List.fromList('Hello User Service'.codeUnits));
  await clientRouter.finishSending(streamId);

  // Ждем обработки
  await Future.delayed(Duration(milliseconds: 50));

  print(
      '✅ Сообщение успешно роутировано! Получено ${receivedMessages.length} сообщений');

  // 5. Демонстрируем валидацию ролей
  print('\n🛡️ Демонстрируем валидацию ролей...');

  try {
    // Попытка создать неправильную конфигурацию
    RpcTransportRouterBuilder.client().routeCall(
        calledServiceName: 'BadService',
        toTransport:
            userClientTransport); // ОШИБКА: клиентский транспорт в клиентском роутере
    print('❌ Валидация не сработала!');
  } catch (e) {
    print('✅ Валидация сработала: ${e.toString().split('\n').first}');
  }

  // 6. Показываем статистику
  print('\n📊 Статистика роутеров:');
  print('   Клиентский router: ${clientRouter.statistics}');
  print('   Серверный router: ${serverRouter.statistics}');

  // 7. Закрываем ресурсы
  print('\n🧹 Закрываем ресурсы...');
  await clientRouter.close();
  await serverRouter.close();
  await userClientTransport.close();
  await userServerTransport.close();
  await paymentClientTransport.close();
  await paymentServerTransport.close();

  print('✅ Пример завершен успешно!');
}

extension RpcMetadataHelper on RpcMetadata {
  String? getHeaderValue(String name) {
    for (final header in headers) {
      if (header.name == name) {
        return header.value;
      }
    }
    return null;
  }
}
