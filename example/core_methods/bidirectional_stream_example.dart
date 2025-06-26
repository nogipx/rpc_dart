// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'package:rpc_dart/rpc_dart.dart';

void main() async {
  await BidirectionalStreamExample.run();
}

/// Пример использования двунаправленного стриминга с контрактами и RpcContext
class BidirectionalStreamExample {
  static Future<void> run() async {
    RpcLogger.setDefaultMinLogLevel(RpcLoggerLevel.debug);
    print('\n=== Пример двунаправленного стриминга с контрактами ===\n');

    // Создаем транспорты
    final (clientTransport, serverTransport) = RpcInMemoryTransport.pair();

    // Создаем серверный эндпоинт и регистрируем контракт
    final serverEndpoint = RpcResponderEndpoint(
      transport: serverTransport,
      debugLabel: 'Server',
      loggerColors: RpcLoggerColors.singleColor(AnsiColor.cyan),
    );

    final service = ChatServiceResponder();
    serverEndpoint.registerServiceContract(service);
    serverEndpoint.start();

    // Создаем клиентский эндпоинт
    final clientEndpoint = RpcCallerEndpoint(
      transport: clientTransport,
      debugLabel: 'Client',
      loggerColors: RpcLoggerColors.singleColor(AnsiColor.brightGreen),
    );

    final client = ChatServiceCaller(clientEndpoint);

    try {
      // Пример 1: Простой чат
      print('\n--- Пример 1: Простой чат ---');

      final context1 = RpcContext.empty()
          .withTraceId('chat-trace-123')
          .withValue('user-id', 'user-456')
          .withValue('session-id', 'session-789');

      final messagesToSend = [
        'ping',
        'время',
        'случайное число',
        'привет, мир!',
        'завершить'
      ];

      final responses = <String>[];

      await client
          .chatWithServer(
        Stream.fromIterable(messagesToSend.map((m) => m.rpc)),
        context: context1,
      )
          .forEach((response) {
        responses.add(response.value);
        print('КЛИЕНТ: Получен ответ: "${response.value}"');
      });

      print('КЛИЕНТ: Получено всего ответов: ${responses.length}');

      // Пример 2: Чат с аутентификацией
      print('\n--- Пример 2: Чат с аутентификацией ---');

      final authContext = RpcContextUtils.withBearerToken('secret-token-123')
          .withAdditionalHeaders({'user-role': 'admin'}).withTraceId(
              'auth-chat-trace-456');

      final secureMessages = [
        'admin:получить статус',
        'admin:получить пользователей',
        'admin:выход'
      ];

      await client
          .chatWithServer(
        Stream.fromIterable(secureMessages.map((m) => m.rpc)),
        context: authContext,
      )
          .forEach((response) {
        print('КЛИЕНТ: Защищенный ответ: "${response.value}"');
      });

      // Пример 3: Чат с отменой
      print('\n--- Пример 3: Чат с отменой ---');

      final cancellationToken = RpcCancellationToken();
      final cancelContext = RpcContext.withCancellation(cancellationToken)
          .withValue('chat-type', 'long-running');

      // Отменяем через 300мс
      Future.delayed(Duration(milliseconds: 300), () {
        print('КЛИЕНТ: Отменяем чат');
        cancellationToken.cancel('User left chat');
      });

      final longMessages = Stream.periodic(
        Duration(milliseconds: 100),
        (i) => 'Сообщение #$i'.rpc,
      ).take(10);

      try {
        await client
            .chatWithServer(longMessages, context: cancelContext)
            .forEach((response) {
          print('КЛИЕНТ: Долгий ответ: "${response.value}"');
        });
      } catch (e) {
        print('КЛИЕНТ: Чат отменен: $e');
      }
    } catch (e, stackTrace) {
      print('ОШИБКА: $e');
      print('StackTrace: $stackTrace');
    } finally {
      await serverEndpoint.close();
      await clientEndpoint.close();
    }

    print('\n=== Пример завершен ===\n');
  }
}

//
// СЕРВЕРНЫЙ КОНТРАКТ
//

abstract interface class IChatServiceContract implements IRpcContract {
  Stream<RpcString> chatWithServer(Stream<RpcString> messages);
}

final class ChatServiceResponder extends RpcResponderContract
    implements IChatServiceContract {
  ChatServiceResponder() : super('ChatService');

  @override
  void setup() {
    addBidirectionalMethod<RpcString, RpcString>(
      methodName: 'ChatWithServer',
      handler: chatWithServer,
      requestCodec: RpcString.codec,
      responseCodec: RpcString.codec,
      description: 'Двунаправленный чат с сервером',
    );
  }

  @override
  Stream<RpcString> chatWithServer(Stream<RpcString> messages,
      {RpcContext? context}) async* {
    final logger = RpcLogger('ChatWithServer');
    logger.info('🔧 Начинаем чат-сессию');
    logger.info('🔍 Context: $context');

    final userId = context?.getValue<String>('user-id');
    final sessionId = context?.getValue<String>('session-id');
    final userRole = context?.getHeader('user-role');
    final authToken = context?.getHeader('authorization');

    logger.info('👤 User: $userId, Session: $sessionId, Role: $userRole');

    // Проверяем аутентификацию для защищенных команд
    final isAuthenticated =
        authToken != null && authToken.startsWith('Bearer ');

    await for (final message in messages) {
      context?.cancellationToken?.throwIfCancelled();

      logger.info('📨 Получено сообщение: "${message.value}"');

      final messageText = message.value;
      String response;

      // Обрабатываем различные типы сообщений
      if (messageText.startsWith('admin:')) {
        if (!isAuthenticated || userRole != 'admin') {
          response = 'Ошибка: Недостаточно прав для выполнения команды';
        } else {
          final command = messageText.substring(6);
          response = _handleAdminCommand(command);
        }
      } else {
        response = _handleRegularMessage(messageText);
      }

      logger.internal('📤 Отправляем ответ: "$response"');
      yield response.rpc;

      // Выходим из чата если получили команду завершения
      if (messageText == 'завершить' || messageText == 'admin:выход') {
        logger.info('✅ Завершаем чат-сессию');
        break;
      }

      await Future.delayed(Duration(milliseconds: 10));
    }
  }

  String _handleAdminCommand(String command) {
    switch (command) {
      case 'получить статус':
        return 'Статус системы: ОК, активных пользователей: 42';
      case 'получить пользователей':
        return 'Активные пользователи: Alice, Bob, Charlie';
      case 'выход':
        return 'Админ-сессия завершена';
      default:
        return 'Неизвестная админ-команда: $command';
    }
  }

  String _handleRegularMessage(String message) {
    switch (message) {
      case 'ping':
        return 'pong';
      case 'время':
        return 'Текущее время: ${DateTime.now()}';
      case 'случайное число':
        final random = (DateTime.now().millisecondsSinceEpoch % 100) + 1;
        return 'Случайное число от 1 до 100: $random';
      case 'завершить':
        return 'До свидания! Чат завершен.';
      default:
        return 'Эхо: $message';
    }
  }
}

//
// КЛИЕНТСКИЙ КОНТРАКТ
//

final class ChatServiceCaller extends RpcCallerContract
    implements IChatServiceContract {
  ChatServiceCaller(RpcCallerEndpoint endpoint)
      : super('ChatService', endpoint);

  @override
  Stream<RpcString> chatWithServer(Stream<RpcString> messages,
      {RpcContext? context}) {
    return callBidirectionalStream<RpcString, RpcString>(
      methodName: 'ChatWithServer',
      requestCodec: RpcString.codec,
      responseCodec: RpcString.codec,
      requests: messages,
      context: context,
    );
  }
}
