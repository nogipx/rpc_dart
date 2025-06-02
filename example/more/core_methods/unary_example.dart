// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: LGPL-3.0-or-later

import 'package:rpc_dart/rpc_dart.dart';

void main() async {
  await UnaryRpcExample.run();
}

/// Пример использования унарного RPC вызова (один запрос - один ответ)
///
/// Демонстрирует простой запрос-ответ с использованием UnaryClient и UnaryServer
/// с поддержкой мультиплексирования по уникальным Stream ID
/// согласно спецификации gRPC.
class UnaryRpcExample {
  /// Запускает демонстрацию унарного RPC вызова
  ///
  /// Создает клиент и сервер с мультиплексированием и выполняет
  /// несколько унарных вызовов разных типов через один транспорт.
  /// Каждый вызов получает уникальный Stream ID.
  static Future<void> run() async {
    RpcLoggerSettings.setDefaultMinLogLevel(RpcLoggerLevel.debug);
    print('\n=== Пример унарного RPC вызова (1 запрос -> 1 ответ) ===\n');

    // Создаем одну пару соединенных транспортов для всех методов
    print('ИНИЦИАЛИЗАЦИЯ: Создание транспортов и регистрация сервисов');
    final (clientTransport, serverTransport) = RpcInMemoryTransport.pair(
      clientLogger: RpcLogger(
        "ClientTransport",
        colors: RpcLoggerColors.singleColor(AnsiColor.brightBlue),
      ),
      serverLogger: RpcLogger(
        "ServerTransport",
        colors: RpcLoggerColors.singleColor(AnsiColor.brightYellow),
      ),
    );

    // Создаем сериализатор для строк
    final stringSerializer = RpcCodec(RpcString.fromJson);

    // Определяем различные сервисы и методы для демонстрации мультиплексирования
    final services = [
      ('GreetingService', 'SayHello'),
      ('TimeService', 'GetCurrentTime'),
      ('StatusService', 'CheckHealth'),
      ('ErrorService', 'ThrowError'),
      ('EchoService', 'Echo'),
    ];

    // Создаем серверы для каждого метода - каждый обрабатывает свой путь
    final servers = <UnaryResponder>[];

    for (final (serviceName, methodName) in services) {
      print('СЕРВЕР: Регистрация метода $serviceName/$methodName');
      final server = UnaryResponder<RpcString, RpcString>(
        transport: serverTransport,
        serviceName: serviceName,
        methodName: methodName,
        requestCodec: stringSerializer,
        responseCodec: stringSerializer,
        handler: (request) {
          print(
              'СЕРВЕР [$serviceName/$methodName]: Получен запрос: "$request"');

          // Обрабатываем разные запросы в зависимости от сервиса
          switch (serviceName) {
            case 'GreetingService':
              final response = 'Здравствуйте! Это ответ от $serviceName';
              print(
                  'СЕРВЕР [$serviceName/$methodName]: Отправляем ответ: "$response"');
              return response.rpc;
            case 'TimeService':
              final response = 'Текущее время: ${DateTime.now()}';
              print(
                  'СЕРВЕР [$serviceName/$methodName]: Отправляем ответ: "$response"');
              return response.rpc;
            case 'StatusService':
              final response = 'Все системы работают нормально в $serviceName';
              print(
                  'СЕРВЕР [$serviceName/$methodName]: Отправляем ответ: "$response"');
              return response.rpc;
            case 'ErrorService':
              final errorMessage = 'Тестовая ошибка от $serviceName';
              print(
                  'СЕРВЕР [$serviceName/$methodName]: Генерируем ошибку: "$errorMessage"');
              throw Exception(errorMessage);
            case 'EchoService':
            default:
              final response = 'Эхо от $serviceName: $request';
              print(
                  'СЕРВЕР [$serviceName/$methodName]: Отправляем ответ: "$response"');
              return response.rpc;
          }
        },
        logger: RpcLogger(
          "$serviceName/$methodName-Server",
          colors: RpcLoggerColors.singleColor(AnsiColor.brightGreen),
        ),
      );
      servers.add(server);
    }

    print(
        '\nИНИЦИАЛИЗАЦИЯ: Все сервисы зарегистрированы, начинаем демонстрацию вызовов\n');

    try {
      // Пример 1: Простой вызов приветствия
      print('\n--- Пример 1: Простой вызов ---');
      print('КЛИЕНТ: Выполняем запрос к GreetingService/SayHello');
      final client1 = UnaryCaller<RpcString, RpcString>(
        transport: clientTransport,
        serviceName: 'GreetingService',
        methodName: 'SayHello',
        requestCodec: stringSerializer,
        responseCodec: stringSerializer,
        logger: RpcLogger(
          "GreetingClient",
          colors: RpcLoggerColors.singleColor(AnsiColor.brightMagenta),
        ),
      );
      final response1 = await client1.call('Привет'.rpc);
      print('КЛИЕНТ: Получен ответ: "$response1"');
      await client1.close(); // Теперь не закрывает транспорт

      // Пример 2: Запрос времени
      print('\n--- Пример 2: Запрос времени ---');
      print('КЛИЕНТ: Выполняем запрос к TimeService/GetCurrentTime');
      final client2 = UnaryCaller<RpcString, RpcString>(
        transport: clientTransport,
        serviceName: 'TimeService',
        methodName: 'GetCurrentTime',
        requestCodec: stringSerializer,
        responseCodec: stringSerializer,
        logger: RpcLogger(
          "TimeClient",
          colors: RpcLoggerColors.singleColor(AnsiColor.brightCyan),
        ),
      );
      final response2 = await client2.call('Время'.rpc);
      print('КЛИЕНТ: Получен ответ: "$response2"');
      await client2.close();

      // Пример 3: Запрос с таймаутом
      print('\n--- Пример 3: Запрос с таймаутом ---');
      print(
          'КЛИЕНТ: Выполняем запрос к StatusService/CheckHealth с таймаутом 500мс');
      final client3 = UnaryCaller<RpcString, RpcString>(
        transport: clientTransport,
        serviceName: 'StatusService',
        methodName: 'CheckHealth',
        requestCodec: stringSerializer,
        responseCodec: stringSerializer,
        logger: RpcLogger(
          "StatusClient",
          colors: RpcLoggerColors.singleColor(AnsiColor.brightWhite),
        ),
      );
      final response3 = await client3.call(
        'Статус'.rpc,
        timeout: Duration(milliseconds: 500),
      );
      print('КЛИЕНТ: Получен ответ: "$response3"');
      await client3.close();

      // Пример 4: Вызов с ошибкой
      print('\n--- Пример 4: Обработка ошибок ---');
      print(
          'КЛИЕНТ: Выполняем запрос к ErrorService/ThrowError (должен вернуть ошибку)');
      final client4 = UnaryCaller<RpcString, RpcString>(
        transport: clientTransport,
        serviceName: 'ErrorService',
        methodName: 'ThrowError',
        requestCodec: stringSerializer,
        responseCodec: stringSerializer,
        logger: RpcLogger(
          "ErrorClient",
          colors: RpcLoggerColors.singleColor(AnsiColor.brightRed),
        ),
      );
      try {
        await client4.call('Ошибка'.rpc);
        print(
            'КЛИЕНТ: Этот текст не должен выводиться, т.к. должна быть ошибка');
      } catch (e) {
        print('КЛИЕНТ: Получена ожидаемая ошибка: $e');
      }
      await client4.close();

      // Пример 5: Эхо-запрос с очень коротким таймаутом
      print('\n--- Пример 5: Таймаут соединения ---');
      print(
          'КЛИЕНТ: Выполняем запрос к EchoService/Echo с очень коротким таймаутом (10мс)');
      final client5 = UnaryCaller<RpcString, RpcString>(
        transport: clientTransport,
        serviceName: 'EchoService',
        methodName: 'Echo',
        requestCodec: stringSerializer,
        responseCodec: stringSerializer,
        logger: RpcLogger(
          "EchoClient",
          colors: RpcLoggerColors.singleColor(AnsiColor.brightBlack),
        ),
      );
      try {
        await client5.call(
          'Эхо тест с таймаутом'.rpc,
          timeout: Duration(milliseconds: 10),
        );
        print(
            'КЛИЕНТ: Этот текст не должен выводиться, т.к. должен быть таймаут');
      } catch (e) {
        print('КЛИЕНТ: Получена ошибка таймаута: $e');
      }
      await client5.close();

      // Демонстрация параллельных запросов к разным сервисам
      print('\n--- Пример 6: Параллельные запросы ---');
      print(
          'КЛИЕНТ: Демонстрация параллельных запросов с уникальными Stream ID');

      final parallelRequests = [
        ('GreetingService', 'SayHello', 'Параллельный привет'),
        ('TimeService', 'GetCurrentTime', 'Параллельное время'),
        ('EchoService', 'Echo', 'Параллельное эхо'),
      ];

      final futures = <Future<void>>[];

      for (final (serviceName, methodName, request) in parallelRequests) {
        final future = () async {
          final client = UnaryCaller<RpcString, RpcString>(
            transport: clientTransport,
            serviceName: serviceName,
            methodName: methodName,
            requestCodec: stringSerializer,
            responseCodec: stringSerializer,
            logger: RpcLogger(
              "$serviceName-ParallelClient",
              colors: RpcLoggerColors.singleColor(AnsiColor.brightGreen),
            ),
          );

          try {
            print(
                'КЛИЕНТ: Параллельный запрос к $serviceName/$methodName: "$request"');
            final response =
                await client.call(request.rpc, timeout: Duration(seconds: 2));
            print(
                'КЛИЕНТ: Параллельный ответ от $serviceName/$methodName: "$response"');
          } catch (e) {
            print(
                'КЛИЕНТ: Параллельная ошибка от $serviceName/$methodName: $e');
          } finally {
            await client.close();
          }
        }();

        futures.add(future);
      }

      // Ждем завершения всех параллельных запросов
      print('КЛИЕНТ: Ожидание завершения всех параллельных запросов...');
      await Future.wait(futures);
      print('КЛИЕНТ: Все параллельные запросы завершены');
    } finally {
      // Закрываем все серверы (они тоже не закрывают транспорт)
      print('\nЗАВЕРШЕНИЕ: Освобождение ресурсов');
      for (final server in servers) {
        await server.close();
      }

      // Закрываем основные транспорты в самом конце
      await clientTransport.close();
      await serverTransport.close();
    }

    print('\n=== Пример унарного RPC вызова завершен ===\n');
  }
}
