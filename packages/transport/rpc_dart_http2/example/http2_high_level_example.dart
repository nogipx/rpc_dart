// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_http2/rpc_dart_http2.dart';

/// 🚀 Минимальный пример HTTP/2 RPC сервера
Future<void> main() async {
  RpcLogger.setDefaultMinLogLevel(RpcLoggerLevel.info);

  const port = 8080;

  // === СОЗДАЕМ СЕРВЕР ===
  final server = RpcHttp2Server(
    port: port,
    onEndpointCreated: (endpoint) {
      // Регистрируем сервис на каждое новое подключение
      endpoint.registerServiceContract(EchoService());
    },
  );

  try {
    await server.start();
    print('🚀 HTTP/2 сервер запущен на порту $port');

    // === СОЗДАЕМ КЛИЕНТА ===
    final transport = await RpcHttp2CallerTransport.connect(
      host: 'localhost',
      port: port,
    );

    try {
      final client = RpcCallerEndpoint(transport: transport);

      // === ВЫПОЛНЯЕМ RPC ВЫЗОВ ===
      final response = await client.unaryRequest<RpcString, RpcString>(
        serviceName: 'Echo',
        methodName: 'Say',
        requestCodec: RpcString.codec,
        responseCodec: RpcString.codec,
        request: RpcString('Привет, HTTP/2!'),
      );

      print('📨 Ответ: "${response.value}"');
    } finally {
      await transport.close();
    }

    // Даем время на корректное закрытие соединений
    await Future.delayed(Duration(milliseconds: 100));
  } finally {
    await server.stop();
  }

  print('✅ Готово!');
}

/// Простой Echo сервис
final class EchoService extends RpcResponderContract {
  EchoService() : super('Echo');

  @override
  void setup() {
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'Say',
      handler: (request, {context}) async => RpcString('Эхо: ${request.value}'),
      requestCodec: RpcString.codec,
      responseCodec: RpcString.codec,
    );
  }
}
