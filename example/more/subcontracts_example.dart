// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: LGPL-3.0-or-later

import 'package:rpc_dart/rpc_dart.dart';

/// Пример использования подконтрактов в RPC
///
/// Демонстрирует, как можно разделить логику на несколько контрактов
/// и автоматически зарегистрировать их вместе с основным контрактом.
void main() async {
  // Настройка логирования для лучшей диагностики
  RpcLoggerSettings.setDefaultMinLogLevel(RpcLoggerLevel.debug);

  final logger = RpcLogger('Main');
  logger.info('Запуск примера подконтрактов');

  // Создаем пару InMemoryTransport
  final (clientTransport, serverTransport) = RpcInMemoryTransport.pair();

  // Создаем серверный эндпоинт
  final serverEndpoint = RpcResponderEndpoint(
    transport: serverTransport,
    debugLabel: 'Server',
    loggerColors: RpcLoggerColors.singleColor(AnsiColor.cyan),
  );

  // Создаем клиентский эндпоинт
  final clientEndpoint = RpcCallerEndpoint(
    transport: clientTransport,
    debugLabel: 'Client',
    loggerColors: RpcLoggerColors.singleColor(AnsiColor.brightGreen),
  );

  // Создаем и регистрируем основной контракт и подконтракты
  logger.info('Регистрация контрактов');
  final mainContract = MainServiceContract();
  serverEndpoint.registerServiceContract(mainContract);

  // Запускаем сервер
  serverEndpoint.start();

  // Создаем клиентский контракт
  final caller = MainServiceCallerContract(clientEndpoint);

  try {
    // Теперь можно вызывать методы как основного контракта, так и подконтрактов
    logger.info('=== Вызов методов основного контракта ===');
    final mainResult = await caller.getMessage('Тестовое сообщение'.rpc);
    logger.info('Ответ от основного контракта: $mainResult');

    logger.info('\n=== Вызов методов подконтракта ===');
    final user = await caller.user.getUser(123.rpc);
    logger.info('Ответ от подконтракта пользователей: $user');

    final notificationResult = await caller.notification.sendNotification(
      'Пользователь ${user.name} вошел в систему'.rpc,
    );
    logger.info('Ответ от подконтракта уведомлений: $notificationResult');
  } catch (e, stackTrace) {
    logger.error('Ошибка при выполнении запросов',
        error: e, stackTrace: stackTrace);
  } finally {
    // Закрываем эндпоинты
    logger.info('Завершение работы');
    await serverEndpoint.close();
    await clientEndpoint.close();
  }
}

//
// СЕРВЕРНЫЕ КОНТРАКТЫ
//

/// Основной контракт сервиса
final class MainServiceContract extends RpcResponderContract {
  final UserServiceContract user;
  final NotificationServiceContract notification;

  MainServiceContract()
      : user = UserServiceContract(),
        notification = NotificationServiceContract(),
        super('MainService');

  @override
  void setup() {
    // Регистрируем подконтракты
    addSubcontract(user);
    addSubcontract(notification);

    // Регистрируем методы основного контракта
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'GetMessage',
      handler: _getMessage,
      requestCodec: RpcString.codec,
      responseCodec: RpcString.codec,
      description: 'Получает сообщение',
    );
  }

  Future<RpcString> _getMessage(RpcString message,
      {RpcContext? context}) async {
    final logger = RpcLogger('MainServiceHandler');
    logger.info('Получен запрос: ${message.value}');
    logger.info(
        'Контекст: trace=${context?.traceId}, request=${context?.requestId}');

    final response = RpcString('Вы отправили: ${message.value}');
    logger.info('Отправляем ответ: ${response.value}');
    return response;
  }
}

/// Подконтракт для работы с пользователями
final class UserServiceContract extends RpcResponderContract {
  UserServiceContract() : super('UserService');

  @override
  void setup() {
    // Регистрируем методы подконтракта пользователей
    addUnaryMethod<RpcInt, UserResponse>(
      methodName: 'GetUser',
      handler: _getUser,
      requestCodec: RpcInt.codec,
      responseCodec: RpcCodec(UserResponse.fromJson),
      description: 'Получает информацию о пользователе по ID',
    );
  }

  Future<UserResponse> _getUser(RpcInt id, {RpcContext? context}) async {
    final logger = RpcLogger('UserServiceHandler');
    final idValue = id.value;
    logger.info('Получен запрос на информацию о пользователе $idValue');
    logger.info(
        'Контекст: trace=${context?.traceId}, request=${context?.requestId}');

    // Имитируем получение данных из БД
    final response = UserResponse(id: idValue, name: 'Пользователь #$idValue');

    logger.info('Возвращаем информацию о пользователе: $response');
    return response;
  }
}

/// Подконтракт для отправки уведомлений
final class NotificationServiceContract extends RpcResponderContract {
  NotificationServiceContract() : super('NotificationService');

  @override
  void setup() {
    // Регистрируем методы подконтракта уведомлений
    addUnaryMethod<RpcString, RpcBool>(
      methodName: 'SendNotification',
      handler: _sendNotification,
      requestCodec: RpcString.codec,
      responseCodec: RpcBool.codec,
      description: 'Отправляет уведомление',
    );
  }

  Future<RpcBool> _sendNotification(RpcString message,
      {RpcContext? context}) async {
    final logger = RpcLogger('NotificationServiceHandler');
    logger.info('Отправка уведомления: ${message.value}');
    logger.info(
        'Контекст: trace=${context?.traceId}, request=${context?.requestId}');
    return const RpcBool(true);
  }
}

//
// КЛИЕНТСКИЕ КОНТРАКТЫ
//

/// Основной клиентский контракт
final class MainServiceCallerContract extends RpcCallerContract {
  final UserServiceCallerContract user;
  final NotificationServiceCallerContract notification;

  MainServiceCallerContract(RpcCallerEndpoint endpoint)
      : user = UserServiceCallerContract(endpoint),
        notification = NotificationServiceCallerContract(endpoint),
        super('MainService', endpoint);

  Future<RpcString> getMessage(RpcString message, {RpcContext? context}) async {
    return await callUnary<RpcString, RpcString>(
      methodName: 'GetMessage',
      requestCodec: RpcString.codec,
      responseCodec: RpcString.codec,
      request: message,
      context: context,
    );
  }
}

/// Клиентский подконтракт для работы с пользователями
final class UserServiceCallerContract extends RpcCallerContract {
  UserServiceCallerContract(RpcCallerEndpoint endpoint)
      : super('UserService', endpoint);

  /// Получает информацию о пользователе по ID
  Future<UserResponse> getUser(RpcInt userId, {RpcContext? context}) async {
    return await callUnary<RpcInt, UserResponse>(
      methodName: 'GetUser',
      requestCodec: RpcInt.codec,
      responseCodec: RpcCodec(UserResponse.fromJson),
      request: userId,
      context: context,
    );
  }
}

/// Клиентский подконтракт для отправки уведомлений
final class NotificationServiceCallerContract extends RpcCallerContract {
  NotificationServiceCallerContract(RpcCallerEndpoint endpoint)
      : super('NotificationService', endpoint);

  /// Отправляет уведомление
  Future<RpcBool> sendNotification(RpcString message,
      {RpcContext? context}) async {
    return await callUnary<RpcString, RpcBool>(
      methodName: 'SendNotification',
      requestCodec: RpcString.codec,
      responseCodec: RpcBool.codec,
      request: message,
      context: context,
    );
  }
}

/// Модель ответа для метода GetUser
class UserResponse implements IRpcSerializable {
  final int id;
  final String name;

  UserResponse({required this.id, required this.name});

  @override
  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
      };

  static UserResponse fromJson(Map<String, dynamic> json) {
    return UserResponse(
      id: json['id'] as int,
      name: json['name'] as String,
    );
  }

  @override
  String toString() => 'User(id: $id, name: $name)';
}
