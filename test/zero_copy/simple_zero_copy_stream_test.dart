// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: LGPL-3.0-or-later

import 'dart:async';
import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

void main() {
  RpcLogger.setDefaultMinLogLevel(RpcLoggerLevel.internal);

  group('🔍 Simple Zero-Copy Stream Debug', () {
    test('📡 Direct Server Stream call', () async {
      print('\n🚀 === ПРЯМОЙ ТЕСТ SERVER STREAM ===');

      final (clientTransport, serverTransport) = RpcInMemoryTransport.pair();

      // Мониторим все сообщения
      final sentMessages = <RpcTransportMessage>[];
      serverTransport.incomingMessages.listen((message) {
        sentMessages.add(message);
        print('\n📥 СООБЩЕНИЕ:');
        print('   Stream ID: ${message.streamId}');
        print('   isDirect: ${message.isDirect}');
        print('   isSerialized: ${message.isSerialized}');
        print('   isMetadataOnly: ${message.isMetadataOnly}');
        print('   isEndOfStream: ${message.isEndOfStream}');
        if (message.isDirect) {
          print('   directPayload: ${message.directPayload}');
        }
        if (message.isSerialized) {
          print('   payload size: ${message.payload?.length} bytes');
        }
      });

      clientTransport.incomingMessages.listen((message) {
        print('\n📤 ОТВЕТ КЛИЕНТУ:');
        print('   Stream ID: ${message.streamId}');
        print('   isDirect: ${message.isDirect}');
        print('   isSerialized: ${message.isSerialized}');
        print('   directPayload: ${message.directPayload}');
      });

      // Прямое создание server stream responder
      final responder = ServerStreamResponder<RpcString, RpcString>(
        id: 1,
        transport: serverTransport,
        serviceName: 'TestService',
        methodName: 'GetNumbers',
        requestCodec: RpcString.codec,
        responseCodec: RpcString.codec,
        handler: (request) async* {
          print('🔥 HANDLER получил запрос: ${request.value}');
          final count = int.tryParse(request.value) ?? 3;
          for (int i = 1; i <= count; i++) {
            print('🔥 HANDLER генерирует ответ $i');
            yield 'Number $i'.rpc;
            await Future.delayed(Duration(milliseconds: 1));
          }
          print('🔥 HANDLER завершен');
        },
      );

      // Привязываем к входящим сообщениям
      responder.bindToMessageStream(
        serverTransport.incomingMessages.where((msg) => msg.streamId == 1),
      );

      // Создаем прямой server stream caller
      final caller = ServerStreamCaller<RpcString, RpcString>(
        transport: clientTransport,
        serviceName: 'TestService',
        methodName: 'GetNumbers',
        requestCodec: RpcString.codec,
        responseCodec: RpcString.codec,
      );

      // Отправляем запрос
      print('📤 Отправляем запрос...');
      final responses = <RpcString>[];

      // Сначала отправляем запрос
      await caller.send('3'.rpc);

      // Затем подписываемся на ответы
      final subscription = caller.responses.listen(
        (rpcMessage) {
          if (!rpcMessage.isMetadataOnly && rpcMessage.payload != null) {
            responses.add(rpcMessage.payload!);
            print('📥 Получен ответ: ${rpcMessage.payload!.value}');
          }
        },
        onError: (e) => print('❌ Ошибка: $e'),
        onDone: () => print('✅ Поток завершен'),
      );

      // Ждем получения ответов
      await Future.delayed(Duration(seconds: 2));

      print('\n📊 ИТОГИ:');
      print('   Получено ответов: ${responses.length}');
      print('   Всего сообщений: ${sentMessages.length}');

      final serializedMessages =
          sentMessages.where((m) => m.isSerialized).length;
      final directMessages = sentMessages.where((m) => m.isDirect).length;

      print('   📡 Сериализованных: $serializedMessages');
      print('   🚀 Zero-copy: $directMessages');

      if (directMessages > 0) {
        print('\n✅ Zero-copy РАБОТАЕТ для стримов!');
      } else {
        print('\n❌ Zero-copy НЕ работает для стримов');
      }

      await subscription.cancel();
      await caller.close();
      await responder.close();
    });
  });
}
