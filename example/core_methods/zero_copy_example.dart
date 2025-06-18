// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: LGPL-3.0-or-later

import 'package:rpc_dart/rpc_dart.dart';

// Пример immutable данных для zero-copy передачи
class UserInfo {
  final String name;
  final int age;
  final List<String> tags;

  const UserInfo({
    required this.name,
    required this.age,
    required this.tags,
  });

  @override
  String toString() => 'UserInfo(name: $name, age: $age, tags: $tags)';
}

void main() async {
  print('🚀 ZERO-COPY пример с RpcInMemoryTransport');

  // Создаем inmemory транспорт с zero-copy поддержкой
  final (client, server) = RpcInMemoryTransport.pair();

  // Подписываемся на входящие сообщения на сервере
  server.incomingMessages.listen((message) {
    if (message.isDirect) {
      print('📦 Получен объект напрямую: ${message.directPayload}');
      print('   Тип объекта: ${message.directPayload.runtimeType}');
      print('   Без сериализации! 🎉');
    } else if (message.isSerialized) {
      print('📡 Получены байты: ${message.payload?.length} bytes');
    }
  });

  // ZERO-COPY: Отправляем объект напрямую!
  final streamId = client.createStream();

  // Создаем immutable объект
  final userInfo = UserInfo(
    name: 'Alice',
    age: 30,
    tags: ['developer', 'flutter', 'dart'],
  );

  print('\n📤 Отправляем объект через zero-copy...');
  await client.sendDirectObject(streamId, userInfo, endStream: true);

  // Ждем немного чтобы увидеть результат
  await Future.delayed(Duration(milliseconds: 100));

  // Сравнение с обычной сериализацией
  print('\n📊 Сравнение методов передачи:');

  // Создаем RPC объект для демонстрации сериализации
  final rpcString = RpcString('Hello World');

  // 1. Обычная сериализация
  final streamId2 = client.createStream();
  final codec = RpcCodec<RpcString>((json) => RpcString.fromJson(json));
  final serialized = codec.serialize(rpcString);
  final framed = RpcMessageFrame.encode(serialized);

  print('  📡 Сериализация: ${framed.length} bytes');
  await client.sendMessage(streamId2, framed, endStream: true);

  // 2. Zero-copy передача
  final streamId3 = client.createStream();
  print('  🚀 Zero-copy: 0 bytes (передача по ссылке)');
  await client.sendDirectObject(streamId3, rpcString, endStream: true);

  // Ждем обработки всех сообщений
  await Future.delayed(Duration(milliseconds: 100));

  print('\n✨ Преимущества zero-copy:');
  print('  • Нет накладных расходов на сериализацию');
  print('  • Нет выделения памяти для байтов');
  print('  • Мгновенная передача по ссылке');
  print('  • Идеально для inmemory архитектуры');

  // Закрываем транспорты
  await client.close();
  await server.close();

  print('\n🎯 Zero-copy готов к использованию в RpcInMemoryTransport!');
}
