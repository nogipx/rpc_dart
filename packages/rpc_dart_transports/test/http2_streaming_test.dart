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
  group('HTTP/2 Streaming RPC Tests', () {
    late Http2StreamingTestServer testServer;

    setUp(() async {
      testServer = Http2StreamingTestServer();
      await testServer.start();
    });

    tearDown(() async {
      await testServer.stop();
    });

    test('server_streaming_rpc_должен_отправлять_множественные_ответы',
        () async {
      // Arrange
      final client = await RpcHttp2CallerTransport.connect(
        host: 'localhost',
        port: testServer.port,
      );

      try {
        final responses = <String>[];
        final completer = Completer<void>();
        var responseCount = 0;

        // Настраиваем сервер для отправки 5 сообщений
        testServer.setServerStreamingHandler((request) async* {
          final baseMessage = utf8.decode(request);
          for (int i = 1; i <= 5; i++) {
            await Future.delayed(Duration(milliseconds: 50));
            yield utf8.encode('$baseMessage Response #$i');
          }
        });

        // Act
        final streamId = client.createStream();

        // Слушаем ответы
        client.getMessagesForStream(streamId).listen(
          (message) {
            if (message.payload != null) {
              final responseText = utf8.decode(message.payload!);
              responses.add(responseText);
              responseCount++;

              print('📨 Получен ответ #$responseCount: $responseText');

              // Завершаем после получения всех ответов
              if (responseCount >= 5) {
                completer.complete();
              }
            }
          },
          onError: (error) => completer.completeError(error),
        );

        // Отправляем запрос
        final metadata =
            RpcMetadata.forClientRequest('StreamService', 'ServerStream');
        await client.sendMetadata(streamId, metadata);
        await client.sendMessage(
            streamId, Uint8List.fromList(utf8.encode('Hello Stream')));
        await client.finishSending(streamId);

        // Assert
        await completer.future.timeout(
          Duration(seconds: 10),
          onTimeout: () => throw TimeoutException(
              'Timeout waiting for server streaming responses'),
        );

        expect(responses.length, equals(5));
        expect(responses[0], equals('Hello Stream Response #1'));
        expect(responses[1], equals('Hello Stream Response #2'));
        expect(responses[2], equals('Hello Stream Response #3'));
        expect(responses[3], equals('Hello Stream Response #4'));
        expect(responses[4], equals('Hello Stream Response #5'));
      } finally {
        await client.close();
      }
    });

    test('client_streaming_rpc_должен_принимать_множественные_запросы',
        () async {
      // Arrange
      final client = await RpcHttp2CallerTransport.connect(
        host: 'localhost',
        port: testServer.port,
      );

      try {
        final responseCompleter = Completer<String>();

        // Настраиваем сервер для аккумуляции клиентских сообщений
        testServer.setClientStreamingHandler((requests) async {
          final allMessages = <String>[];
          await for (final request in requests) {
            final message = utf8.decode(request);
            allMessages.add(message);
            print('📥 Сервер получил: $message');
          }
          return utf8.encode(
              'Received ${allMessages.length} messages: ${allMessages.join(", ")}');
        });

        // Act
        final streamId = client.createStream();

        // Слушаем финальный ответ
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

        // Отправляем метаданные
        final metadata =
            RpcMetadata.forClientRequest('StreamService', 'ClientStream');
        await client.sendMetadata(streamId, metadata);

        // Отправляем множественные сообщения
        for (int i = 1; i <= 3; i++) {
          await Future.delayed(Duration(milliseconds: 100));
          final message = 'Message #$i';
          print('📤 Отправляем: $message');
          await client.sendMessage(
              streamId, Uint8List.fromList(utf8.encode(message)));
        }

        // Завершаем отправку
        await client.finishSending(streamId);

        // Assert
        final response = await responseCompleter.future.timeout(
          Duration(seconds: 3),
          onTimeout: () => throw TimeoutException(
              'Timeout waiting for client streaming response'),
        );

        expect(response,
            equals('Received 3 messages: Message #1, Message #2, Message #3'));
      } finally {
        await client.close();
      }
    });

    test('bidirectional_streaming_rpc_должен_обрабатывать_двусторонний_поток',
        () async {
      // Arrange
      final client = await RpcHttp2CallerTransport.connect(
        host: 'localhost',
        port: testServer.port,
      );

      try {
        final responses = <String>[];
        final responseCompleter = Completer<void>();
        var expectedResponses = 3;

        // Настраиваем bidirectional обработчик
        testServer.setBidirectionalHandler((requests) async* {
          await for (final request in requests) {
            final message = utf8.decode(request);
            print('🔄 Сервер получил и обрабатывает: $message');

            // Эхо с добавлением префикса
            yield utf8.encode('Echo: $message');
          }
        });

        // Act
        final streamId = client.createStream();

        // Слушаем ответы
        client.getMessagesForStream(streamId).listen(
          (message) {
            if (message.payload != null) {
              final responseText = utf8.decode(message.payload!);
              responses.add(responseText);
              print('🔄 Клиент получил: $responseText');

              if (responses.length >= expectedResponses) {
                responseCompleter.complete();
              }
            }
          },
          onError: (error) => responseCompleter.completeError(error),
        );

        // Отправляем метаданные
        final metadata = RpcMetadata.forClientRequest(
            'StreamService', 'BidirectionalStream');
        await client.sendMetadata(streamId, metadata);

        // Отправляем сообщения с интервалами
        for (int i = 1; i <= 3; i++) {
          await Future.delayed(Duration(milliseconds: 200));
          final message = 'Bidirectional Message #$i';
          print('🔄 Клиент отправляет: $message');
          await client.sendMessage(
              streamId, Uint8List.fromList(utf8.encode(message)));
        }

        // Завершаем отправку
        await client.finishSending(streamId);

        // Assert
        await responseCompleter.future.timeout(
          Duration(seconds: 10),
          onTimeout: () => throw TimeoutException(
              'Timeout waiting for bidirectional responses'),
        );

        expect(responses.length, equals(3));
        expect(responses[0], equals('Echo: Bidirectional Message #1'));
        expect(responses[1], equals('Echo: Bidirectional Message #2'));
        expect(responses[2], equals('Echo: Bidirectional Message #3'));
      } finally {
        await client.close();
      }
    });

    test('смешанные_потоки_должны_работать_параллельно', () async {
      // Arrange
      final client = await RpcHttp2CallerTransport.connect(
        host: 'localhost',
        port: testServer.port,
      );

      try {
        // Настраиваем все handlers
        testServer.setServerStreamingHandler((request) async* {
          for (int i = 1; i <= 2; i++) {
            yield utf8.encode('Server Stream #$i');
          }
        });

        testServer.setClientStreamingHandler((requests) async {
          var count = 0;
          await for (final _ in requests) {
            count++;
          }
          return utf8.encode('Client sent $count messages');
        });

        // Параллельные вызовы
        final futures = <Future>[];

        // Server streaming вызов
        futures.add(_testServerStreaming(client));

        // Client streaming вызов
        futures.add(_testClientStreaming(client));

        // Act & Assert
        await Future.wait(futures).timeout(
          Duration(seconds: 10),
          onTimeout: () =>
              throw TimeoutException('Timeout in parallel streaming test'),
        );

        print('✅ Все параллельные streaming вызовы завершены успешно');
      } finally {
        await client.close();
      }
    });
  });
}

/// Выполняет server streaming тест
Future<void> _testServerStreaming(RpcHttp2CallerTransport client) async {
  final responses = <String>[];
  final completer = Completer<void>();

  final streamId = client.createStream();

  client.getMessagesForStream(streamId).listen(
    (message) {
      if (message.payload != null) {
        responses.add(utf8.decode(message.payload!));
        if (responses.length >= 2) {
          completer.complete();
        }
      }
    },
    onError: (error) => completer.completeError(error),
  );

  final metadata =
      RpcMetadata.forClientRequest('StreamService', 'ServerStream');
  await client.sendMetadata(streamId, metadata);
  await client.sendMessage(streamId, Uint8List.fromList(utf8.encode('Test')));
  await client.finishSending(streamId);

  await completer.future;
  expect(responses.length, equals(2));
}

/// Выполняет client streaming тест
Future<void> _testClientStreaming(RpcHttp2CallerTransport client) async {
  final responseCompleter = Completer<String>();

  final streamId = client.createStream();

  client.getMessagesForStream(streamId).listen(
    (message) {
      if (message.payload != null && !responseCompleter.isCompleted) {
        responseCompleter.complete(utf8.decode(message.payload!));
      }
    },
    onError: (error) {
      if (!responseCompleter.isCompleted) {
        responseCompleter.completeError(error);
      }
    },
  );

  final metadata =
      RpcMetadata.forClientRequest('StreamService', 'ClientStream');
  await client.sendMetadata(streamId, metadata);

  for (int i = 1; i <= 2; i++) {
    await Future.delayed(
        Duration(milliseconds: 50)); // Задержка между сообщениями
    await client.sendMessage(
        streamId, Uint8List.fromList(utf8.encode('Message $i')));
  }
  await client.finishSending(streamId);

  final response = await responseCompleter.future;
  expect(response, equals('Client sent 2 messages'));
}

/// Расширенный HTTP/2 тестовый сервер с поддержкой streaming
class Http2StreamingTestServer {
  ServerSocket? _serverSocket;
  int _port = 0;
  final List<StreamSubscription> _subscriptions = [];

  // Handlers для разных типов streaming
  Stream<Uint8List> Function(Uint8List)? _serverStreamingHandler;
  Future<Uint8List> Function(Stream<Uint8List>)? _clientStreamingHandler;
  Stream<Uint8List> Function(Stream<Uint8List>)? _bidirectionalHandler;

  int get port => _port;

  void setServerStreamingHandler(
      Stream<Uint8List> Function(Uint8List) handler) {
    _serverStreamingHandler = handler;
  }

  void setClientStreamingHandler(
      Future<Uint8List> Function(Stream<Uint8List>) handler) {
    _clientStreamingHandler = handler;
  }

  void setBidirectionalHandler(
      Stream<Uint8List> Function(Stream<Uint8List>) handler) {
    _bidirectionalHandler = handler;
  }

  Future<void> start() async {
    _serverSocket = await ServerSocket.bind('localhost', 0);
    _port = _serverSocket!.port;

    print('🚀 HTTP/2 Streaming тестовый сервер запущен на порту $_port');

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

    print('🛑 HTTP/2 Streaming тестовый сервер остановлен');
  }

  void _handleConnection(Socket socket) {
    print(
        '📞 Новое streaming подключение от ${socket.remoteAddress}:${socket.remotePort}');

    try {
      final connection = http2.ServerTransportConnection.viaSocket(socket);
      final transport = RpcHttp2ResponderTransport(connection: connection);

      final subscription = transport.incomingMessages.listen(
        (message) async {
          await _handleStreamingMessage(transport, message);
        },
        onError: (error) {
          print('❌ Ошибка в HTTP/2 streaming соединении: $error');
        },
        onDone: () {
          print('🔌 HTTP/2 streaming соединение закрыто');
        },
      );

      _subscriptions.add(subscription);
    } catch (e) {
      print('❌ Ошибка при создании HTTP/2 streaming соединения: $e');
      socket.destroy();
    }
  }

  // Отслеживаем типы streams
  final Map<int, String> _streamTypes = <int, String>{};

  Future<void> _handleStreamingMessage(
      RpcHttp2ResponderTransport transport, RpcTransportMessage message) async {
    try {
      if (message.isMetadataOnly) {
        final methodPath = message.methodPath ?? 'Unknown';
        print('📋 Получены streaming метаданные: $methodPath');

        // Запоминаем тип stream
        _streamTypes[message.streamId] = methodPath;

        // Отправляем начальные метаданные ответа
        final responseMetadata = RpcMetadata.forServerInitialResponse();
        await transport.sendMetadata(message.streamId, responseMetadata);

        // Запускаем обработчики для типов, которые не требуют ждать данных
        if (methodPath.contains('ClientStream')) {
          await _handleClientStreaming(transport, message.streamId);
        } else if (methodPath.contains('BidirectionalStream')) {
          await _handleBidirectionalStreaming(transport, message.streamId);
        }
      } else if (message.payload != null) {
        // Данные получены
        print(
            '📦 Получены streaming данные для stream ${message.streamId}, размер: ${message.payload!.length}');

        final streamType = _streamTypes[message.streamId];

        // Для server streaming обрабатываем данные сразу
        if (streamType != null && streamType.contains('ServerStream')) {
          await _handleServerStreamingData(
              transport, message.streamId, message.payload!);
        }
      }
    } catch (e) {
      print('❌ Ошибка при обработке streaming сообщения: $e');
    }
  }

  /// Обрабатывает данные для server streaming
  Future<void> _handleServerStreamingData(RpcHttp2ResponderTransport transport,
      int streamId, Uint8List data) async {
    if (_serverStreamingHandler == null) return;

    print('📡 Обрабатываем server streaming запрос, размер: ${data.length}');

    try {
      // Обрабатываем через handler
      final responseStream = _serverStreamingHandler!(data);

      await for (final responseData in responseStream) {
        print(
            '📡 Отправляем server streaming ответ, размер: ${responseData.length}');
        await transport.sendMessage(streamId, responseData);
        await Future.delayed(Duration(milliseconds: 20)); // Небольшая задержка
      }

      await transport.finishSending(streamId);
      print('✅ Server streaming завершен для stream $streamId');
    } catch (e) {
      print('❌ Ошибка в server streaming data: $e');
    }
  }

  Future<void> _handleClientStreaming(
      RpcHttp2ResponderTransport transport, int streamId) async {
    if (_clientStreamingHandler == null) return;

    print('📥 Запуск client streaming для stream $streamId');

    try {
      // Создаем контроллер для накопления сообщений
      final messageController = StreamController<Uint8List>();

      // Слушаем входящие сообщения и накапливаем их
      final subscription = transport.getMessagesForStream(streamId).listen(
        (msg) {
          if (msg.payload != null) {
            print(
                '📥 Получено client streaming сообщение, размер: ${msg.payload!.length}');
            if (!messageController.isClosed) {
              messageController.add(msg.payload!);
            }
          }

          // Если это конец потока, закрываем контроллер
          if (msg.isEndOfStream) {
            print('📥 Получен END_STREAM, завершаем накопление');
            if (!messageController.isClosed) {
              messageController.close();
            }
          }
        },
        onDone: () {
          print('📥 Поток входящих сообщений завершен');
          if (!messageController.isClosed) {
            messageController.close();
          }
        },
        onError: (error) {
          print('❌ Ошибка в потоке входящих сообщений: $error');
          if (!messageController.isClosed) {
            messageController.addError(error);
          }
        },
      );

      // Обрабатываем накопленные сообщения через handler
      final result = await _clientStreamingHandler!(messageController.stream);

      // Отправляем финальный ответ
      print('📥 Отправляем client streaming ответ, размер: ${result.length}');

      // Проверяем что транспорт еще активен
      try {
        await transport.sendMessage(streamId, result);
        await transport.finishSending(streamId);
      } catch (e) {
        print('❌ Ошибка при отправке client streaming ответа: $e');
        return;
      }

      await subscription.cancel();
      print('✅ Client streaming завершен для stream $streamId');
    } catch (e) {
      print('❌ Ошибка в client streaming: $e');
    }
  }

  Future<void> _handleBidirectionalStreaming(
      RpcHttp2ResponderTransport transport, int streamId) async {
    if (_bidirectionalHandler == null) return;

    print('🔄 Запуск bidirectional streaming для stream $streamId');

    try {
      // Получаем поток входящих сообщений
      final incomingMessages = transport
          .getMessagesForStream(streamId)
          .where((msg) => msg.payload != null)
          .map((msg) => msg.payload!);

      // Обрабатываем через handler и отправляем ответы
      final responseStream = _bidirectionalHandler!(incomingMessages);

      await for (final responseData in responseStream) {
        print(
            '🔄 Отправляем bidirectional ответ, размер: ${responseData.length}');
        await transport.sendMessage(streamId, responseData);
        await Future.delayed(Duration(milliseconds: 20)); // Небольшая задержка
      }

      await transport.finishSending(streamId);
      print('✅ Bidirectional streaming завершен для stream $streamId');
    } catch (e) {
      print('❌ Ошибка в bidirectional streaming: $e');
    }
  }
}
