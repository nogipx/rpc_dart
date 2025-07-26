// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';
import 'dart:io';

import 'package:test/test.dart';
import 'package:http2/http2.dart' as http2;
import 'package:rpc_dart_transports/rpc_dart_transports.dart';

void main() {
  group('HTTP/2 RPC Integration Tests (High-Level API)', () {
    late Http2RpcTestServer testServer;
    late RpcHttp2CallerTransport clientTransport;
    late RpcCallerEndpoint callerEndpoint;

    setUpAll(() async {
      testServer = Http2RpcTestServer();
      await testServer.start();

      // Создаем одно долгоживущее соединение для всех тестов
      clientTransport = await RpcHttp2CallerTransport.connect(
        host: 'localhost',
        port: testServer.port,
        logger: RpcLogger('TestClient'),
      );

      callerEndpoint = RpcCallerEndpoint(transport: clientTransport);

      print('🔗 Установлено долгоживущее RPC соединение');
    });

    tearDownAll(() async {
      await callerEndpoint.close();
      await testServer.stop();
      print('🔒 Долгоживущее RPC соединение закрыто');
    });

    test('unary_rpc_через_caller_и_responder', () async {
      // Act - делаем унарный RPC вызов через high-level API
      final response = await callerEndpoint.unaryRequest<RpcString, RpcString>(
        serviceName: 'TestService',
        methodName: 'Echo',
        requestCodec: RpcString.codec,
        responseCodec: RpcString.codec,
        request: RpcString('Hello from high-level RPC!'),
      );

      // Assert
      expect(response.value, equals('Server Echo: Hello from high-level RPC!'));

      print('✅ Unary RPC через Caller/Responder работает отлично!');
    });

    test('server_streaming_rpc_через_caller_и_responder', () async {
      final responses = <String>[];
      final completer = Completer<void>();

      // Act - создаем server streaming RPC вызов
      final responseStream = callerEndpoint.serverStream<RpcString, RpcString>(
        serviceName: 'TestService',
        methodName: 'ServerStream',
        requestCodec: RpcString.codec,
        responseCodec: RpcString.codec,
        request: RpcString('Generate messages'),
      );

      // Слушаем ответы
      responseStream.listen(
        (rpcString) {
          responses.add(rpcString.value);
          print('📨 Получен server streaming ответ: ${rpcString.value}');

          if (responses.length >= 3) {
            completer.complete();
          }
        },
        onError: (error) => completer.completeError(error),
        onDone: () {
          if (!completer.isCompleted) {
            completer.complete();
          }
        },
      );

      // Assert
      await completer.future.timeout(
        Duration(seconds: 15),
        onTimeout: () =>
            throw TimeoutException('Timeout waiting for server streaming'),
      );

      expect(responses.length, equals(3));
      expect(responses[0], contains('Stream message #1'));
      expect(responses[1], contains('Stream message #2'));
      expect(responses[2], contains('Stream message #3'));

      print('✅ Server Streaming RPC через Caller/Responder работает отлично!');
    });

    test('client_streaming_rpc_через_caller_и_responder', () async {
      // Act - создаем client streaming RPC вызов
      final messages = [
        RpcString('Message 1'),
        RpcString('Message 2'),
        RpcString('Message 3')
      ];

      final requestStream = Stream.fromIterable(messages).map((msg) {
        print('📤 Отправляем client streaming сообщение: ${msg.value}');
        return msg;
      });

      final callFunction = callerEndpoint.clientStream<RpcString, RpcString>(
        serviceName: 'TestService',
        methodName: 'ClientStream',
        requestCodec: RpcString.codec,
        responseCodec: RpcString.codec,
      );

      // Завершаем отправку и ждем ответ
      final response = await callFunction(requestStream).timeout(
        Duration(seconds: 5),
        onTimeout: () => throw TimeoutException(
            'Timeout waiting for client streaming response'),
      );

      // Assert
      expect(response.value, contains('Received 3 client messages'));

      print('✅ Client Streaming RPC через Caller/Responder работает отлично!');
    });

    test('bidirectional_streaming_rpc_через_caller_и_responder', () async {
      final responses = <String>[];
      final completer = Completer<void>();

      // Act - создаем bidirectional streaming RPC вызов
      final messages = [
        RpcString('Bidirectional message #1'),
        RpcString('Bidirectional message #2'),
        RpcString('Bidirectional message #3')
      ];

      // Создаем StreamController для контроля закрытия
      final requestController = StreamController<RpcString>();

      // Отправляем сообщения с задержкой но НЕ закрываем стрим сразу
      Future.microtask(() async {
        for (final msg in messages) {
          await Future.delayed(Duration(milliseconds: 200));
          print('🔄 Отправляем bidirectional сообщение: ${msg.value}');
          requestController.add(msg);
        }

        // Ждем немного перед закрытием чтобы дать серверу время ответить
        await Future.delayed(Duration(milliseconds: 300));
        print('🏁 Клиент закрывает request stream');
        requestController.close();
      });

      final requestStream = requestController.stream;

      final responseStream =
          callerEndpoint.bidirectionalStream<RpcString, RpcString>(
        serviceName: 'TestService',
        methodName: 'BidirectionalStream',
        requestCodec: RpcString.codec,
        responseCodec: RpcString.codec,
        requests: requestStream,
      );

      // Слушаем ответы
      responseStream.listen(
        (rpcString) {
          responses.add(rpcString.value);
          print('🔄 Получен bidirectional ответ: ${rpcString.value}');

          if (responses.length >= 3) {
            completer.complete();
          }
        },
        onError: (error) => completer.completeError(error),
        onDone: () {
          print('🏁 Bidirectional response stream завершен');
          if (!completer.isCompleted) {
            completer.complete();
          }
        },
      );

      // Assert
      await completer.future.timeout(
        Duration(seconds: 30),
        onTimeout: () => throw TimeoutException(
            'Timeout waiting for bidirectional responses'),
      );

      expect(responses.length, equals(3));
      expect(responses[0], equals('Echo: Bidirectional message #1'));
      expect(responses[1], equals('Echo: Bidirectional message #2'));
      expect(responses[2], equals('Echo: Bidirectional message #3'));

      print(
          '✅ Bidirectional Streaming RPC через Caller/Responder работает отлично!');
    });

    test('параллельные_rpc_вызовы_разных_типов', () async {
      // Act - делаем параллельные вызовы разных типов
      final futures = <Future>[];

      // Unary вызов
      futures.add(
        callerEndpoint
            .unaryRequest<RpcString, RpcString>(
          serviceName: 'TestService',
          methodName: 'Echo',
          requestCodec: RpcString.codec,
          responseCodec: RpcString.codec,
          request: RpcString('Parallel unary'),
        )
            .then((response) {
          expect(response.value, contains('Parallel unary'));
          print('✅ Параллельный unary завершен: ${response.value}');
        }),
      );

      // Server streaming вызов
      futures.add(
        callerEndpoint
            .serverStream<RpcString, RpcString>(
              serviceName: 'TestService',
              methodName: 'ServerStream',
              requestCodec: RpcString.codec,
              responseCodec: RpcString.codec,
              request: RpcString('Parallel server stream'),
            )
            .take(2)
            .toList()
            .then((responses) {
          expect(responses.length, equals(2));
          print(
              '✅ Параллельный server streaming завершен: ${responses.length} ответов');
        }),
      );

      // Assert
      await Future.wait(futures).timeout(
        Duration(seconds: 15),
        onTimeout: () => throw TimeoutException('Timeout in parallel RPC test'),
      );

      print(
          '✅ Все параллельные RPC вызовы через Caller/Responder завершены успешно!');
    });
  });
}

/// HTTP/2 RPC тестовый сервер с полноценным RpcResponderEndpoint
class Http2RpcTestServer {
  ServerSocket? _serverSocket;
  int _port = 0;
  final List<StreamSubscription> _subscriptions = [];
  final List<RpcResponderEndpoint> _responderEndpoints = [];

  int get port => _port;

  Future<void> start() async {
    _serverSocket = await ServerSocket.bind('localhost', 0);
    _port = _serverSocket!.port;

    print('🚀 HTTP/2 RPC тестовый сервер запущен на порту $_port');

    final subscription = _serverSocket!.listen((socket) {
      _handleConnection(socket);
    });

    _subscriptions.add(subscription);
  }

  Future<void> stop() async {
    // Даем время на завершение всех активных RPC операций
    await Future.delayed(Duration(milliseconds: 100));

    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    _subscriptions.clear();

    for (final endpoint in _responderEndpoints) {
      await endpoint.close();
    }
    _responderEndpoints.clear();

    await _serverSocket?.close();
    _serverSocket = null;

    print('🛑 HTTP/2 RPC тестовый сервер остановлен');
  }

  void _handleConnection(Socket socket) {
    print(
        '📞 Новое RPC подключение от ${socket.remoteAddress}:${socket.remotePort}');

    try {
      // Создаем HTTP/2 соединение и серверный транспорт
      final connection = http2.ServerTransportConnection.viaSocket(socket);
      final serverTransport =
          RpcHttp2ResponderTransport(connection: connection);

      // Создаем RpcResponderEndpoint с HTTP/2 транспортом
      final responderEndpoint =
          RpcResponderEndpoint(transport: serverTransport);
      _responderEndpoints.add(responderEndpoint);

      // Регистрируем тестовый сервис
      _registerTestService(responderEndpoint);

      // Запускаем endpoint
      responderEndpoint.start();
    } catch (e) {
      print('❌ Ошибка при создании RPC соединения: $e');
      socket.destroy();
    }
  }

  /// Регистрирует тестовый сервис с различными типами RPC методов
  void _registerTestService(RpcResponderEndpoint endpoint) {
    final contract = TestServiceContract();
    endpoint.registerServiceContract(contract);
    print(
        '📋 Зарегистрирован TestService с ${contract.methods.length} методами');
  }
}

/// Контракт тестового сервиса
final class TestServiceContract extends RpcResponderContract {
  TestServiceContract() : super('TestService');

  @override
  void setup() {
    // Unary метод
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'Echo',
      handler: (request, {context}) async {
        final message = request.value;
        print('🔄 Обработка unary Echo: $message');
        return RpcString('Server Echo: $message');
      },
      requestCodec: RpcString.codec,
      responseCodec: RpcString.codec,
    );

    // Server streaming метод
    addServerStreamMethod<RpcString, RpcString>(
      methodName: 'ServerStream',
      handler: (request, {context}) async* {
        final message = request.value;
        print('🔄 Обработка server streaming: $message');

        for (int i = 1; i <= 3; i++) {
          await Future.delayed(Duration(milliseconds: 100));
          yield RpcString('Stream message #$i for: $message');
        }
      },
      requestCodec: RpcString.codec,
      responseCodec: RpcString.codec,
    );

    // Client streaming метод
    addClientStreamMethod<RpcString, RpcString>(
      methodName: 'ClientStream',
      handler: (requestStream, {context}) async {
        print('🔄 Начало обработки client streaming');

        final messages = <String>[];
        await for (final request in requestStream) {
          final message = request.value;
          messages.add(message);
          print('📥 Получено client streaming сообщение: $message');
        }

        return RpcString(
            'Received ${messages.length} client messages: ${messages.join(", ")}');
      },
      requestCodec: RpcString.codec,
      responseCodec: RpcString.codec,
    );

    // Bidirectional streaming метод
    addBidirectionalMethod<RpcString, RpcString>(
      methodName: 'BidirectionalStream',
      handler: (requestStream, {context}) async* {
        print('🔄 Начало обработки bidirectional streaming');

        await for (final request in requestStream) {
          final message = request.value;
          print('🔄 Обработка bidirectional сообщения: $message');

          final response = RpcString('Echo: $message');
          print('📤 Отправляем bidirectional ответ: ${response.value}');
          yield response;

          // Добавляем небольшую задержку чтобы ответ успел отправиться
          await Future.delayed(Duration(milliseconds: 50));
          print('✅ Bidirectional ответ отправлен: ${response.value}');
        }

        print('🏁 Завершение bidirectional streaming на сервере');
      },
      requestCodec: RpcString.codec,
      responseCodec: RpcString.codec,
    );
  }
}
