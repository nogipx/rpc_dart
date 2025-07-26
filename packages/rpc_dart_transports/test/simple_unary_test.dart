// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:io';
import 'package:rpc_dart_transports/rpc_dart_transports.dart';
import 'package:test/test.dart';
import 'package:web_socket_channel/io.dart';

void main() {
  group('Простой унарный тест', () {
    late HttpServer server;
    late List<WebSocket> serverSockets;

    setUpAll(() async {
      RpcLogger.setDefaultMinLogLevel(RpcLoggerLevel.debug);
    });

    setUp(() async {
      serverSockets = [];
      server = await HttpServer.bind('localhost', 0);

      // Обрабатываем WebSocket соединения
      server.listen((request) async {
        if (WebSocketTransformer.isUpgradeRequest(request)) {
          final socket = await WebSocketTransformer.upgrade(request);
          serverSockets.add(socket);

          final channel = IOWebSocketChannel(socket);
          final transport = RpcWebSocketResponderTransport(
            channel,
            logger: RpcLogger('TestServerWebSocket'),
          );

          final endpoint = RpcResponderEndpoint(
              transport: transport, debugLabel: 'TestServerEndpoint');

          final contract = TestEchoContract();
          endpoint.registerServiceContract(contract);
          endpoint.start();

          socket.done.then((_) => endpoint.close());
        }
      });
    });

    tearDown(() async {
      for (final socket in serverSockets) {
        await socket.close();
      }
      await server.close();
    });

    test('Унарный echo запрос должен работать', () async {
      final port = server.port;

      // Создаем клиент
      final transport = RpcWebSocketCallerTransport.connect(
        Uri.parse('ws://localhost:$port'),
        logger: RpcLogger('TestClientWebSocket'),
      );

      final endpoint = RpcCallerEndpoint(
        transport: transport,
        debugLabel: 'TestClientEndpoint',
      );

      try {
        // Отправляем простой запрос
        final response =
            await endpoint.unaryRequest<SimpleMessage, SimpleMessage>(
          serviceName: 'test',
          methodName: 'echo',
          requestCodec:
              RpcCodec<SimpleMessage>((json) => SimpleMessage.fromJson(json)),
          responseCodec:
              RpcCodec<SimpleMessage>((json) => SimpleMessage.fromJson(json)),
          request: SimpleMessage('Hello World'),
        );

        expect(response.value, equals('Echo: Hello World'));
      } finally {
        await endpoint.close();
      }
    });
  });
}

/// Простое тестовое сообщение
class SimpleMessage implements IRpcSerializable {
  final String value;

  SimpleMessage(this.value);

  @override
  Map<String, dynamic> toJson() => {'value': value};

  factory SimpleMessage.fromJson(Map<String, dynamic> json) {
    return SimpleMessage(json['value'] as String);
  }
}

/// Простой тестовый контракт
base class TestEchoContract extends RpcResponderContract {
  TestEchoContract() : super('test') {
    addUnaryMethod<SimpleMessage, SimpleMessage>(
      methodName: 'echo',
      requestCodec:
          RpcCodec<SimpleMessage>((json) => SimpleMessage.fromJson(json)),
      responseCodec:
          RpcCodec<SimpleMessage>((json) => SimpleMessage.fromJson(json)),
      handler: (request, {context}) async {
        print('Сервер получил: ${request.value}');
        return SimpleMessage('Echo: ${request.value}');
      },
    );
  }
}
