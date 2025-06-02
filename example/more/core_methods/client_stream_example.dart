import 'package:rpc_dart/rpc_dart.dart';

void main() async {
  await ClientStreamingExample.run();
}

/// Пример использования клиентского стриминга (много запросов, один ответ)
///
/// Демонстрирует, как клиент отправляет поток запросов и получает один ответ
class ClientStreamingExample {
  /// Запускает демонстрацию клиентского стриминга (много запросов, один ответ)
  static Future<void> run() async {
    RpcLoggerSettings.setDefaultMinLogLevel(RpcLoggerLevel.debug);

    print('\n=== Пример клиентского стриминга (N запросов -> 1 ответ) ===\n');

    // Создаем пару соединенных транспортов
    final (clientTransport, serverTransport) = RpcInMemoryTransport.pair();

    // Создаем сериализаторы для строк
    final stringSerializer = RpcCodec(RpcString.fromJson);

    // Инициализируем серверную часть с обработчиком
    final server = ClientStreamResponder<RpcString, RpcString>(
      id: 1,
      transport: serverTransport,
      serviceName: 'DataAggregatorService',
      methodName: 'ProcessClientStream',
      requestCodec: stringSerializer,
      responseCodec: stringSerializer,
      logger: RpcLogger(
        'ClientStreamingExample',
        colors: RpcLoggerColors.singleColor(AnsiColor.brightMagenta),
      ),
      handler: (Stream<RpcString> requests) async {
        print('СЕРВЕР: Ожидаем запросы...');

        int count = 0;
        await for (final request in requests) {
          print('  - $request');
          count++;
        }

        // Небольшая задержка перед отправкой ответа
        await Future.delayed(Duration(milliseconds: 50));

        // Формируем и возвращаем итоговый ответ
        final response = 'Обработано $count запросов';
        print('СЕРВЕР: Отправляем ответ: "$response"');
        return response.rpc;
      },
    );

    // ВАЖНО: Привязываем сервер к потоку сообщений для streamId = 1
    server.bindToMessageStream(
      serverTransport.incomingMessages.where((msg) => msg.streamId == 1),
    );

    // Инициализируем клиентскую часть
    final client = ClientStreamCaller<RpcString, RpcString>(
      transport: clientTransport,
      serviceName: 'DataAggregatorService',
      methodName: 'ProcessClientStream',
      requestCodec: stringSerializer,
      responseCodec: stringSerializer,
      logger: RpcLogger(
        'ClientStreamingExample',
        colors: RpcLoggerColors.singleColor(AnsiColor.brightMagenta),
      ),
    );

    // Отправляем несколько запросов
    final requests = [
      'Часть 1: Привет',
      'Часть 2: Как дела?',
      'Часть 3: Это тест',
      'Часть 4: Клиентского',
      'Часть 5: Стриминга!'
    ];

    for (final request in requests) {
      print('КЛИЕНТ: Отправляем запрос: "$request"');
      client.send(request.rpc);
      await Future.delayed(Duration(milliseconds: 50));
    }

    // Ждем итоговый ответ с увеличенным таймаутом
    print('КЛИЕНТ: Ожидаем итоговый ответ от сервера...');
    try {
      // Ждем до 5 секунд, чтобы дать серверу больше времени
      final response = await client.finishSending().timeout(
            Duration(seconds: 5),
            onTimeout: () => 'Таймаут ожидания ответа'.rpc,
          );
      print('КЛИЕНТ: Получен итоговый ответ: "$response"');
    } catch (e) {
      print('КЛИЕНТ: Ошибка при получении ответа: $e');
    }

    // Ждем завершения обработки
    print('КЛИЕНТ: Ждем завершения обработки...');
    await Future.delayed(Duration(milliseconds: 500));

    // Закрываем ресурсы
    print('КЛИЕНТ: Закрываем ресурсы');
    await client.close();
    await server.close();

    print('\n=== Пример клиентского стриминга завершен ===\n');
  }
}
