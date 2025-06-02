import 'package:rpc_dart/rpc_dart.dart';

void main() async {
  await ServerStreamingExample.run();
}

/// Пример использования серверного стриминга (один запрос, много ответов)
///
/// Демонстрирует, как клиент отправляет один запрос и получает поток ответов
class ServerStreamingExample {
  /// Запускает демонстрацию серверного стриминга (один запрос, много ответов)
  static Future<void> run() async {
    RpcLoggerSettings.setDefaultMinLogLevel(RpcLoggerLevel.debug);

    print('\n=== Пример серверного стриминга (1 запрос -> N ответов) ===\n');

    // Создаем пару соединенных транспортов
    final (clientTransport, serverTransport) = RpcInMemoryTransport.pair();

    // Создаем сериализаторы для строк
    final stringSerializer = RpcCodec(RpcString.fromJson);

    // Инициализируем серверную часть с обработчиком
    final server = ServerStreamResponder<RpcString, RpcString>(
      id: 1,
      transport: serverTransport,
      serviceName: 'DataService',
      methodName: 'GetServerStream',
      requestCodec: stringSerializer,
      responseCodec: stringSerializer,
      logger: RpcLogger(
        'ServerStreamingExample',
        colors: RpcLoggerColors.singleColor(AnsiColor.brightGreen),
      ),
      handler: (request) async* {
        print('СЕРВЕР: Получен запрос: "$request"');

        // Отправляем несколько ответов с задержкой
        for (int i = 1; i <= 5; i++) {
          final response = 'Ответ #$i на запрос "$request"';
          print('СЕРВЕР: Отправляем: "$response"');
          yield response.rpc;

          // Делаем реальную задержку между ответами
          await Future.delayed(Duration(milliseconds: 50));
        }

        // Завершаем поток ответов
        print('СЕРВЕР: Завершаем поток ответов');
      },
    );

    // ВАЖНО: Привязываем сервер к потоку сообщений для streamId = 1
    server.bindToMessageStream(
      serverTransport.incomingMessages.where((msg) => msg.streamId == 1),
    );

    // Инициализируем клиентскую часть
    final client = ServerStreamCaller<RpcString, RpcString>(
      transport: clientTransport,
      serviceName: 'DataService',
      methodName: 'GetServerStream',
      requestCodec: stringSerializer,
      responseCodec: stringSerializer,
      logger: RpcLogger(
        'ServerStreamingExample',
        colors: RpcLoggerColors.singleColor(AnsiColor.brightGreen),
      ),
    );

    // Подписываемся на поток ответов
    final subscription = client.responses.listen(
      (message) {
        if (!message.isMetadataOnly) {
          print('КЛИЕНТ: Получен ответ: "${message.payload}"');
        }
      },
      onError: (error, stackTrace) {
        if (error.toString().contains('Cannot add event after closing')) {
          print('КЛИЕНТ: Игнорируем ожидаемую ошибку при закрытии потока');
        } else {
          print('КЛИЕНТ: Ошибка: $error');
        }
      },
      onDone: () {
        print('КЛИЕНТ: Поток ответов завершен');
      },
    );

    // Отправляем единственный запрос
    print('КЛИЕНТ: Отправляем запрос: "Дай мне данные"');
    await client.send('Дай мне данные'.rpc);

    // Ждем завершения обработки всех ответов
    print('КЛИЕНТ: Ждем завершения обработки...');
    await Future.delayed(Duration(milliseconds: 1000));

    print('КЛИЕНТ: Поток ответов должен уже завершиться...');
    // Закрываем ресурсы
    await subscription.cancel();
    await client.close();
    await server.close();

    print('\n=== Пример серверного стриминга завершен ===\n');
  }
}
