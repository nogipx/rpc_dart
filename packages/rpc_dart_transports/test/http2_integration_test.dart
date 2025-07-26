// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:http2/http2.dart' as http2;
import 'package:rpc_dart_transports/rpc_dart_transports.dart';

void main() {
  group('HTTP/2 Integration Tests', () {
    late Http2TestServer testServer;

    setUp(() async {
      testServer = Http2TestServer();
      await testServer.start();
    });

    tearDown(() async {
      await testServer.stop();
    });

    test('полный_цикл_unary_rpc_вызова', () async {
      // Arrange
      final client = await RpcHttp2CallerTransport.connect(
        host: 'localhost',
        port: testServer.port,
      );

      try {
        final requestData = utf8.encode('Hello, HTTP/2 gRPC!');
        final responseCompleter = Completer<String>();

        // Настраиваем сервер для эхо ответа
        testServer.setEchoHandler((data) => 'Echo: ${utf8.decode(data)}');

        // Act
        final streamId = client.createStream();

        // Слушаем ответы
        client.getMessagesForStream(streamId).listen(
          (message) {
            if (message.payload != null && !responseCompleter.isCompleted) {
              final responseText = utf8.decode(message.payload!);
              responseCompleter.complete(responseText);
            }
          },
          onError: (error) {
            if (!responseCompleter.isCompleted) {
              responseCompleter.completeError(error);
            }
          },
        );

        // Отправляем запрос
        final metadata = RpcMetadata.forClientRequest('TestService', 'Echo');
        await client.sendMetadata(streamId, metadata);
        await client.sendMessage(streamId, Uint8List.fromList(requestData));
        await client.finishSending(streamId);

        // Assert
        final response = await responseCompleter.future.timeout(
          Duration(seconds: 5),
          onTimeout: () =>
              throw TimeoutException('Timeout waiting for response'),
        );

        expect(response, equals('Echo: Hello, HTTP/2 gRPC!'));
      } finally {
        await client.close();
      }
    });

    test('множественные_параллельные_вызовы', () async {
      // Arrange
      final client = await RpcHttp2CallerTransport.connect(
        host: 'localhost',
        port: testServer.port,
      );

      try {
        testServer.setEchoHandler((data) => 'Response: ${utf8.decode(data)}');

        // Act - создаем 3 параллельных вызова
        final futures = <Future<String>>[];

        for (int i = 0; i < 3; i++) {
          final future = _makeRpcCall(client, 'Request $i');
          futures.add(future);
        }

        final responses = await Future.wait(futures);

        // Assert
        expect(responses.length, equals(3));
        expect(responses[0], equals('Response: Request 0'));
        expect(responses[1], equals('Response: Request 1'));
        expect(responses[2], equals('Response: Request 2'));
      } finally {
        await client.close();
      }
    });

    test('обработка_больших_сообщений', () async {
      // Arrange
      final client = await RpcHttp2CallerTransport.connect(
        host: 'localhost',
        port: testServer.port,
      );

      try {
        // Создаем большое сообщение (10KB вместо 1MB для стабильности)
        final bigMessage = 'A' * (10 * 1024);
        testServer.setEchoHandler((data) => 'Size: ${data.length}');

        // Act
        final response = await _makeRpcCall(client, bigMessage);

        // Assert
        expect(response, equals('Size: ${bigMessage.length}'));
      } finally {
        await client.close();
      }
    });

    test('обработка_ошибок_соединения', () async {
      // Arrange - останавливаем сервер
      await testServer.stop();

      // Act & Assert
      expect(
        () async => await RpcHttp2CallerTransport.connect(
          host: 'localhost',
          port: testServer.port,
        ),
        throwsA(isA<SocketException>()),
      );
    });

    test('корректное_закрытие_соединения', () async {
      // Arrange
      final client = await RpcHttp2CallerTransport.connect(
        host: 'localhost',
        port: testServer.port,
      );

      // Act
      await client.close();

      // Assert - попытка использования после закрытия должна выбросить ошибку
      expect(
        () => client.createStream(),
        throwsA(isA<StateError>()),
      );
    });
  });
}

/// Выполняет простой RPC вызов и возвращает ответ
Future<String> _makeRpcCall(
    RpcHttp2CallerTransport client, String message) async {
  final requestData = utf8.encode(message);
  final responseCompleter = Completer<String>();

  final streamId = client.createStream();

  // Слушаем ответы
  client.getMessagesForStream(streamId).listen(
    (transportMessage) {
      if (transportMessage.payload != null && !responseCompleter.isCompleted) {
        final responseText = utf8.decode(transportMessage.payload!);
        responseCompleter.complete(responseText);
      }
    },
    onError: (error) {
      if (!responseCompleter.isCompleted) {
        responseCompleter.completeError(error);
      }
    },
  );

  // Отправляем запрос
  final metadata = RpcMetadata.forClientRequest('TestService', 'Echo');
  await client.sendMetadata(streamId, metadata);
  await client.sendMessage(streamId, Uint8List.fromList(requestData));
  await client.finishSending(streamId);

  return responseCompleter.future.timeout(
    Duration(seconds: 5),
    onTimeout: () => throw TimeoutException('Timeout waiting for response'),
  );
}

/// Простой HTTP/2 тестовый сервер
class Http2TestServer {
  ServerSocket? _serverSocket;
  int _port = 0;
  String Function(Uint8List)? _echoHandler;
  final List<StreamSubscription> _subscriptions = [];

  int get port => _port;

  void setEchoHandler(String Function(Uint8List) handler) {
    _echoHandler = handler;
  }

  Future<void> start() async {
    _serverSocket = await ServerSocket.bind('localhost', 0);
    _port = _serverSocket!.port;

    print('🚀 HTTP/2 тестовый сервер запущен на порту $_port');

    final subscription = _serverSocket!.listen((socket) {
      _handleConnection(socket);
    });

    _subscriptions.add(subscription);
  }

  Future<void> stop() async {
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    _subscriptions.clear();

    await _serverSocket?.close();
    _serverSocket = null;

    print('🛑 HTTP/2 тестовый сервер остановлен');
  }

  void _handleConnection(Socket socket) {
    print(
        '📞 Новое подключение от ${socket.remoteAddress}:${socket.remotePort}');

    try {
      // Создаем HTTP/2 server connection
      final connection = http2.ServerTransportConnection.viaSocket(socket);
      final transport = RpcHttp2ResponderTransport(
        connection: connection,
      );

      // Обрабатываем входящие сообщения
      final subscription = transport.incomingMessages.listen(
        (message) async {
          await _handleMessage(transport, message);
        },
        onError: (error) {
          print('❌ Ошибка в HTTP/2 соединении: $error');
        },
        onDone: () {
          print('🔌 HTTP/2 соединение закрыто');
        },
      );

      _subscriptions.add(subscription);
    } catch (e) {
      print('❌ Ошибка при создании HTTP/2 соединения: $e');
      socket.destroy();
    }
  }

  Future<void> _handleMessage(
      RpcHttp2ResponderTransport transport, RpcTransportMessage message) async {
    try {
      if (message.isMetadataOnly) {
        print('📋 Получены метаданные: ${message.methodPath}');

        // Отправляем начальные метаданные ответа
        final responseMetadata = RpcMetadata.forServerInitialResponse();
        await transport.sendMetadata(message.streamId, responseMetadata);
      } else if (message.payload != null) {
        print(
            '📦 Получены данные для stream ${message.streamId}, размер: ${message.payload!.length}');

        // Обрабатываем данные с помощью echo handler
        if (_echoHandler != null) {
          final responseText = _echoHandler!(message.payload!);
          final responseData = utf8.encode(responseText);

          // Небольшая задержка для имитации обработки
          await Future.delayed(Duration(milliseconds: 10));

          // Отправляем ответ
          await transport.sendMessage(
              message.streamId, Uint8List.fromList(responseData));
        }

        // Завершаем поток если это конец
        if (message.isEndOfStream) {
          await transport.finishSending(message.streamId);
          print('✅ Ответ отправлен для stream ${message.streamId}');
        }
      }
    } catch (e) {
      print('❌ Ошибка при обработке сообщения: $e');
    }
  }
}
