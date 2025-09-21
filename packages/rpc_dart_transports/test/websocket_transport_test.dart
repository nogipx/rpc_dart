// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';

import 'package:rpc_dart_transports/rpc_dart_transports.dart';
import 'package:test/test.dart';
import 'package:universal_io/io.dart';
import 'package:web_socket_channel/io.dart';

void main() {
  group('RpcWebSocketTransport тесты (реальный сервер, ephemeral port)', () {
    late HttpServer server;
    late StreamController<WebSocket> socketEvents;
    late StreamSubscription<HttpRequest> serverSub;

    setUpAll(() async {
      // Детальное логирование для тестов
      RpcLogger.setDefaultMinLogLevel(RpcLoggerLevel.debug);
    });

    setUp(() async {
      // Эфемерный порт (0) — ОС выдаст свободный
      server = await HttpServer.bind('localhost', 0);
      socketEvents = StreamController<WebSocket>.broadcast();

      // Обрабатываем WebSocket upgrade
      serverSub = server.listen((request) async {
        try {
          if (WebSocketTransformer.isUpgradeRequest(request)) {
            final ws = await WebSocketTransformer.upgrade(request);
            socketEvents.add(ws);
          } else {
            request.response.statusCode = HttpStatus.badRequest;
            request.response.write('WebSocket connection required');
            await request.response.close();
          }
        } catch (e, st) {
          // Если апгрейд/ответ упал — стараемся закрыть ответ, шлём событие об ошибке
          try {
            request.response.statusCode = HttpStatus.internalServerError;
            await request.response.close();
          } catch (_) {}
          socketEvents.addError(e, st);
        }
      });
    });

    tearDown(() async {
      await serverSub.cancel();
      await server.close(force: true);
      await socketEvents.close();
    });

    /// Удобный хелпер: ждём первое входящее WS-подключение
    Future<WebSocket> nextServerSocket({
      Duration timeout = const Duration(seconds: 2),
    }) {
      return socketEvents.stream.first.timeout(timeout);
    }

    test('создание caller и responder транспортов', () async {
      // Клиент коннектится к реальному серверу
      final clientTransport = RpcWebSocketCallerTransport.connect(
        Uri.parse('ws://localhost:${server.port}'),
        logger: RpcLogger('TestClient'),
      );

      // Ждём, когда сервер примет сокет, и оборачиваем его в канал
      final serverSocket = await nextServerSocket();
      final serverTransport = RpcWebSocketResponderTransport(
        IOWebSocketChannel(serverSocket),
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
      final serverSocket = await nextServerSocket();
      final serverTransport = RpcWebSocketResponderTransport(
        IOWebSocketChannel(serverSocket),
        logger: RpcLogger('TestServer'),
      );

      // Клиент должен генерировать нечетные
      final c1 = clientTransport.createStream();
      final c2 = clientTransport.createStream();
      expect(c1 % 2, 1);
      expect(c2 % 2, 1);
      expect(c2, greaterThan(c1));

      // Сервер — четные
      final s1 = serverTransport.createStream();
      final s2 = serverTransport.createStream();
      expect(s1 % 2, 0);
      expect(s2 % 2, 0);
      expect(s2, greaterThan(s1));

      await clientTransport.close();
      await serverTransport.close();
    });

    test('отправка и получение метаданных', () async {
      final clientTransport = RpcWebSocketCallerTransport.connect(
        Uri.parse('ws://localhost:${server.port}'),
        logger: RpcLogger('TestClient'),
      );
      final serverSocket = await nextServerSocket();
      final serverTransport = RpcWebSocketResponderTransport(
        IOWebSocketChannel(serverSocket),
        logger: RpcLogger('TestServer'),
      );

      final streamId = clientTransport.createStream();

      final serverMessages = <RpcTransportMessage>[];
      final sub = serverTransport.incomingMessages.listen(serverMessages.add);

      final metadata = RpcMetadata.forClientRequestWithPath(
        '/test.Service/TestMethod',
      );
      await clientTransport.sendMetadata(streamId, metadata);

      // Дадим очереди событий обработаться
      await pump();

      expect(serverMessages.length, 1);
      final received = serverMessages.first;
      expect(received.streamId, streamId);
      expect(received.metadata, isNotNull);
      expect(received.metadata!.methodPath, '/test.Service/TestMethod');

      final headers = received.metadata!.headers;
      expect(
        headers.any(
          (h) => h.name == 'content-type' && h.value == 'application/grpc',
        ),
        isTrue,
      );
      expect(
        headers.any(
          (h) => h.name == ':path' && h.value == '/test.Service/TestMethod',
        ),
        isTrue,
      );

      await sub.cancel();
      await clientTransport.close();
      await serverTransport.close();
    });

    test('отправка и получение данных', () async {
      final clientTransport = RpcWebSocketCallerTransport.connect(
        Uri.parse('ws://localhost:${server.port}'),
        logger: RpcLogger('TestClient'),
      );
      final serverSocket = await nextServerSocket();
      final serverTransport = RpcWebSocketResponderTransport(
        IOWebSocketChannel(serverSocket),
        logger: RpcLogger('TestServer'),
      );

      final streamId = clientTransport.createStream();

      final serverMessages = <RpcTransportMessage>[];
      final sub = serverTransport.incomingMessages.listen(serverMessages.add);

      final testData = Uint8List.fromList([1, 2, 3, 4, 5]);
      await clientTransport.sendMessage(streamId, testData);

      await pump();

      expect(serverMessages.length, 1);
      final m = serverMessages.first;
      expect(m.streamId, streamId);
      expect(m.payload, equals(testData));

      await sub.cancel();
      await clientTransport.close();
      await serverTransport.close();
    });

    test('двунаправленная коммуникация', () async {
      final clientTransport = RpcWebSocketCallerTransport.connect(
        Uri.parse('ws://localhost:${server.port}'),
        logger: RpcLogger('TestClient'),
      );
      final serverSocket = await nextServerSocket();
      final serverTransport = RpcWebSocketResponderTransport(
        IOWebSocketChannel(serverSocket),
        logger: RpcLogger('TestServer'),
      );

      final clientStreamId = clientTransport.createStream();
      final serverStreamId = serverTransport.createStream();

      final clientMsgs = <RpcTransportMessage>[];
      final serverMsgs = <RpcTransportMessage>[];

      final cSub = clientTransport.incomingMessages.listen(clientMsgs.add);
      final sSub = serverTransport.incomingMessages.listen(serverMsgs.add);

      final clientData = Uint8List.fromList([10, 20, 30]);
      await clientTransport.sendMessage(clientStreamId, clientData);

      final serverData = Uint8List.fromList([40, 50, 60]);
      await serverTransport.sendMessage(serverStreamId, serverData);

      await pump();

      // Сервер получил от клиента
      expect(serverMsgs.length, 1);
      expect(serverMsgs.first.streamId, clientStreamId);
      expect(serverMsgs.first.payload, equals(clientData));

      // Клиент получил от сервера
      expect(clientMsgs.length, 1);
      expect(clientMsgs.first.streamId, serverStreamId);
      expect(clientMsgs.first.payload, equals(serverData));

      await cSub.cancel();
      await sSub.cancel();
      await clientTransport.close();
      await serverTransport.close();
    });

    test('finishSending отправляет end stream', () async {
      final clientTransport = RpcWebSocketCallerTransport.connect(
        Uri.parse('ws://localhost:${server.port}'),
        logger: RpcLogger('TestClient'),
      );
      final serverSocket = await nextServerSocket();
      final serverTransport = RpcWebSocketResponderTransport(
        IOWebSocketChannel(serverSocket),
        logger: RpcLogger('TestServer'),
      );

      final streamId = clientTransport.createStream();

      final serverMessages = <RpcTransportMessage>[];
      final sub = serverTransport.incomingMessages.listen(serverMessages.add);

      final data = Uint8List.fromList([1, 2, 3]);
      await clientTransport.sendMessage(streamId, data);
      await clientTransport.finishSending(streamId);

      await pump();

      expect(serverMessages.length, 2);
      final dataMsg = serverMessages[0];
      final endMsg = serverMessages[1];

      expect(dataMsg.payload, equals(data));
      expect(dataMsg.isEndOfStream, isFalse);

      expect(endMsg.isEndOfStream, isTrue);

      await sub.cancel();
      await clientTransport.close();
      await serverTransport.close();
    });

    test('getMessagesForStream фильтрует по stream ID', () async {
      final clientTransport = RpcWebSocketCallerTransport.connect(
        Uri.parse('ws://localhost:${server.port}'),
        logger: RpcLogger('TestClient'),
      );
      final serverSocket = await nextServerSocket();
      final serverTransport = RpcWebSocketResponderTransport(
        IOWebSocketChannel(serverSocket),
        logger: RpcLogger('TestServer'),
      );

      final id1 = clientTransport.createStream();
      final id2 = clientTransport.createStream();

      final stream1Msgs = <RpcTransportMessage>[];
      final sub =
          serverTransport.getMessagesForStream(id1).listen(stream1Msgs.add);

      final data1 = Uint8List.fromList([1, 1, 1]);
      final data2 = Uint8List.fromList([2, 2, 2]);

      await clientTransport.sendMessage(id1, data1);
      await clientTransport.sendMessage(id2, data2);

      await pump();

      expect(stream1Msgs.length, 1);
      expect(stream1Msgs.first.streamId, id1);
      expect(stream1Msgs.first.payload, equals(data1));

      await sub.cancel();
      await clientTransport.close();
      await serverTransport.close();
    });

    test('освобождение stream ID', () async {
      final clientTransport = RpcWebSocketCallerTransport.connect(
        Uri.parse('ws://localhost:${server.port}'),
        logger: RpcLogger('TestClient'),
      );
      final _ = await nextServerSocket(); // серверный сокет нам тут не нужен

      final id1 = clientTransport.createStream();
      final id2 = clientTransport.createStream();

      expect(clientTransport.idManager.isActive(id1), isTrue);
      expect(clientTransport.idManager.isActive(id2), isTrue);
      expect(clientTransport.idManager.activeCount, equals(2));

      final released = clientTransport.releaseStreamId(id1);
      expect(released, isTrue);
      expect(clientTransport.idManager.isActive(id1), isFalse);
      expect(clientTransport.idManager.isActive(id2), isTrue);
      expect(clientTransport.idManager.activeCount, equals(1));

      final releasedAgain = clientTransport.releaseStreamId(id1);
      expect(releasedAgain, isFalse);

      await clientTransport.close();
    });
  });
}

/// Микро-хелпер: даём микротакт event-loop’у
Future<void> pump([Duration d = const Duration(milliseconds: 50)]) =>
    Future<void>.delayed(d);
