// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';
import 'dart:io';

import 'package:rpc_dart_transports/rpc_dart_transports.dart';
import 'package:test/test.dart';
import 'package:web_socket_channel/io.dart';

void main() {
  group('RpcWebSocketTransport тесты', () {
    late HttpServer server;
    late List<WebSocket> serverSockets;

    setUpAll(() async {
      // Устанавливаем уровень логирования DEBUG для тестов
      RpcLogger.setDefaultMinLogLevel(RpcLoggerLevel.debug);
    });

    setUp(() async {
      serverSockets = [];
      // Создаем HTTP сервер для WebSocket соединений
      server = await HttpServer.bind('localhost', 0);

      // Обрабатываем WebSocket соединения
      server.listen((request) async {
        if (WebSocketTransformer.isUpgradeRequest(request)) {
          final socket = await WebSocketTransformer.upgrade(request);
          serverSockets.add(socket);
        }
      });
    });

    tearDown(() async {
      for (final socket in serverSockets) {
        if (socket.readyState == WebSocket.open) {
          await socket.close();
        }
      }
      await server.close();
    });

    test('создание caller и responder транспортов', () async {
      // Создаем клиентский транспорт
      final clientTransport = RpcWebSocketCallerTransport.connect(
        Uri.parse('ws://localhost:${server.port}'),
        logger: RpcLogger('TestClient'),
      );

      // Ждем подключения
      await Future.delayed(Duration(milliseconds: 300));
      expect(serverSockets.length, equals(1));

      // Создаем серверный транспорт
      final serverTransport = RpcWebSocketResponderTransport(
        IOWebSocketChannel(serverSockets.first),
        logger: RpcLogger('TestServer'),
      );

      expect(clientTransport, isNotNull);
      expect(serverTransport, isNotNull);

      await clientTransport.close();
      await serverTransport.close();
    });

    test('createStream генерирует корректные ID', () async {
      final clientTransport = RpcWebSocketCallerTransport.connect(
        Uri.parse('ws://localhost:${server.port}'),
        logger: RpcLogger('TestClient'),
      );

      await Future.delayed(Duration(milliseconds: 100));

      final serverTransport = RpcWebSocketResponderTransport(
        IOWebSocketChannel(serverSockets.first),
        logger: RpcLogger('TestServer'),
      );

      // Клиент должен генерировать нечетные ID
      final clientStream1 = clientTransport.createStream();
      final clientStream2 = clientTransport.createStream();
      expect(clientStream1 % 2, equals(1)); // нечетный
      expect(clientStream2 % 2, equals(1)); // нечетный
      expect(clientStream2, greaterThan(clientStream1));

      // Сервер должен генерировать четные ID
      final serverStream1 = serverTransport.createStream();
      final serverStream2 = serverTransport.createStream();
      expect(serverStream1 % 2, equals(0)); // четный
      expect(serverStream2 % 2, equals(0)); // четный
      expect(serverStream2, greaterThan(serverStream1));

      await clientTransport.close();
      await serverTransport.close();
    });

    test('отправка и получение метаданных', () async {
      final clientTransport = RpcWebSocketCallerTransport.connect(
        Uri.parse('ws://localhost:${server.port}'),
        logger: RpcLogger('TestClient'),
      );

      await Future.delayed(Duration(milliseconds: 100));

      final serverTransport = RpcWebSocketResponderTransport(
        IOWebSocketChannel(serverSockets.first),
        logger: RpcLogger('TestServer'),
      );

      final streamId = clientTransport.createStream();

      // Подписываемся на входящие сообщения на сервере
      final serverMessages = <RpcTransportMessage>[];
      final serverSubscription = serverTransport.incomingMessages.listen(
        (message) => serverMessages.add(message),
      );

      // Отправляем метаданные с клиента - используем готовый метод
      final metadata =
          RpcMetadata.forClientRequestWithPath('/test.Service/TestMethod');

      await clientTransport.sendMetadata(streamId, metadata);

      // Ждем получения сообщения
      await Future.delayed(Duration(milliseconds: 100));

      expect(serverMessages.length, equals(1));
      final receivedMessage = serverMessages.first;
      expect(receivedMessage.streamId, equals(streamId));
      expect(receivedMessage.metadata, isNotNull);

      // Проверяем путь метода
      expect(receivedMessage.metadata!.methodPath,
          equals('/test.Service/TestMethod'));

      // Проверяем заголовки
      final headers = receivedMessage.metadata!.headers;
      expect(
          headers.any(
              (h) => h.name == 'content-type' && h.value == 'application/grpc'),
          isTrue);
      expect(
          headers.any((h) =>
              h.name == ':path' && h.value == '/test.Service/TestMethod'),
          isTrue);

      await serverSubscription.cancel();
      await clientTransport.close();
      await serverTransport.close();
    });

    test('отправка и получение данных', () async {
      final clientTransport = RpcWebSocketCallerTransport.connect(
        Uri.parse('ws://localhost:${server.port}'),
        logger: RpcLogger('TestClient'),
      );

      await Future.delayed(Duration(milliseconds: 100));

      final serverTransport = RpcWebSocketResponderTransport(
        IOWebSocketChannel(serverSockets.first),
        logger: RpcLogger('TestServer'),
      );

      final streamId = clientTransport.createStream();

      // Подписываемся на входящие сообщения на сервере
      final serverMessages = <RpcTransportMessage>[];
      final serverSubscription = serverTransport.incomingMessages.listen(
        (message) => serverMessages.add(message),
      );

      // Отправляем данные
      final testData = Uint8List.fromList([1, 2, 3, 4, 5]);
      await clientTransport.sendMessage(streamId, testData);

      // Ждем получения сообщения
      await Future.delayed(Duration(milliseconds: 100));

      expect(serverMessages.length, equals(1));
      final receivedMessage = serverMessages.first;
      expect(receivedMessage.streamId, equals(streamId));
      expect(receivedMessage.payload, isNotNull);
      expect(receivedMessage.payload, equals(testData));

      await serverSubscription.cancel();
      await clientTransport.close();
      await serverTransport.close();
    });

    test('двунаправленная коммуникация', () async {
      final clientTransport = RpcWebSocketCallerTransport.connect(
        Uri.parse('ws://localhost:${server.port}'),
        logger: RpcLogger('TestClient'),
      );

      await Future.delayed(Duration(milliseconds: 100));

      final serverTransport = RpcWebSocketResponderTransport(
        IOWebSocketChannel(serverSockets.first),
        logger: RpcLogger('TestServer'),
      );

      final clientStreamId = clientTransport.createStream();
      final serverStreamId = serverTransport.createStream();

      // Подписываемся на входящие сообщения
      final clientMessages = <RpcTransportMessage>[];
      final serverMessages = <RpcTransportMessage>[];

      final clientSubscription = clientTransport.incomingMessages.listen(
        (message) => clientMessages.add(message),
      );
      final serverSubscription = serverTransport.incomingMessages.listen(
        (message) => serverMessages.add(message),
      );

      // Клиент отправляет данные серверу
      final clientData = Uint8List.fromList([10, 20, 30]);
      await clientTransport.sendMessage(clientStreamId, clientData);

      // Сервер отправляет данные клиенту
      final serverData = Uint8List.fromList([40, 50, 60]);
      await serverTransport.sendMessage(serverStreamId, serverData);

      // Ждем получения сообщений
      await Future.delayed(Duration(milliseconds: 100));

      // Проверяем, что сервер получил данные от клиента
      expect(serverMessages.length, equals(1));
      final serverReceivedMessage = serverMessages.first;
      expect(serverReceivedMessage.streamId, equals(clientStreamId));
      expect(serverReceivedMessage.payload, equals(clientData));

      // Проверяем, что клиент получил данные от сервера
      expect(clientMessages.length, equals(1));
      final clientReceivedMessage = clientMessages.first;
      expect(clientReceivedMessage.streamId, equals(serverStreamId));
      expect(clientReceivedMessage.payload, equals(serverData));

      await clientSubscription.cancel();
      await serverSubscription.cancel();
      await clientTransport.close();
      await serverTransport.close();
    });

    test('finishSending отправляет end stream', () async {
      final clientTransport = RpcWebSocketCallerTransport.connect(
        Uri.parse('ws://localhost:${server.port}'),
        logger: RpcLogger('TestClient'),
      );

      await Future.delayed(Duration(milliseconds: 100));

      final serverTransport = RpcWebSocketResponderTransport(
        IOWebSocketChannel(serverSockets.first),
        logger: RpcLogger('TestServer'),
      );

      final streamId = clientTransport.createStream();

      // Подписываемся на входящие сообщения на сервере
      final serverMessages = <RpcTransportMessage>[];
      final serverSubscription = serverTransport.incomingMessages.listen(
        (message) => serverMessages.add(message),
      );

      // Отправляем данные, затем завершаем поток
      final testData = Uint8List.fromList([1, 2, 3]);
      await clientTransport.sendMessage(streamId, testData);
      await clientTransport.finishSending(streamId);

      // Ждем получения сообщений
      await Future.delayed(Duration(milliseconds: 100));

      // Должно быть 2 сообщения: одно с данными, одно с флагом завершения
      expect(serverMessages.length, equals(2));

      final dataMessage = serverMessages[0];
      expect(dataMessage.payload, equals(testData));
      expect(dataMessage.isEndOfStream, isFalse);

      final endMessage = serverMessages[1];
      expect(endMessage.isEndOfStream, isTrue);

      await serverSubscription.cancel();
      await clientTransport.close();
      await serverTransport.close();
    });

    test('getMessagesForStream фильтрует по stream ID', () async {
      final clientTransport = RpcWebSocketCallerTransport.connect(
        Uri.parse('ws://localhost:${server.port}'),
        logger: RpcLogger('TestClient'),
      );

      await Future.delayed(Duration(milliseconds: 100));

      final serverTransport = RpcWebSocketResponderTransport(
        IOWebSocketChannel(serverSockets.first),
        logger: RpcLogger('TestServer'),
      );

      final streamId1 = clientTransport.createStream();
      final streamId2 = clientTransport.createStream();

      // Подписываемся на сообщения для конкретного потока
      final stream1Messages = <RpcTransportMessage>[];
      final stream1Subscription =
          serverTransport.getMessagesForStream(streamId1).listen(
                (message) => stream1Messages.add(message),
              );

      // Отправляем данные в разные потоки
      final data1 = Uint8List.fromList([1, 1, 1]);
      final data2 = Uint8List.fromList([2, 2, 2]);

      await clientTransport.sendMessage(streamId1, data1);
      await clientTransport.sendMessage(streamId2, data2);

      // Ждем получения сообщений
      await Future.delayed(Duration(milliseconds: 100));

      // Должно быть получено только сообщение для streamId1
      expect(stream1Messages.length, equals(1));
      expect(stream1Messages.first.streamId, equals(streamId1));
      expect(stream1Messages.first.payload, equals(data1));

      await stream1Subscription.cancel();
      await clientTransport.close();
      await serverTransport.close();
    });

    test('освобождение stream ID', () async {
      final clientTransport = RpcWebSocketCallerTransport.connect(
        Uri.parse('ws://localhost:${server.port}'),
        logger: RpcLogger('TestClient'),
      );

      await Future.delayed(Duration(milliseconds: 100));

      final streamId1 = clientTransport.createStream();
      final streamId2 = clientTransport.createStream();

      // Проверяем, что ID активны
      expect(clientTransport.idManager.isActive(streamId1), isTrue);
      expect(clientTransport.idManager.isActive(streamId2), isTrue);
      expect(clientTransport.idManager.activeCount, equals(2));

      // Освобождаем один ID
      final released = clientTransport.releaseStreamId(streamId1);
      expect(released, isTrue);
      expect(clientTransport.idManager.isActive(streamId1), isFalse);
      expect(clientTransport.idManager.isActive(streamId2), isTrue);
      expect(clientTransport.idManager.activeCount, equals(1));

      // Попытка освободить уже освобожденный ID
      final releasedAgain = clientTransport.releaseStreamId(streamId1);
      expect(releasedAgain, isFalse);

      await clientTransport.close();
    });
  });
}
