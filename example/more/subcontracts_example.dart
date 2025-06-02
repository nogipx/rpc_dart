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
  final transportLogger = RpcLogger('Transport');
  final (clientTransport, serverTransport) = RpcInMemoryTransport.pair(
    clientLogger: transportLogger,
    serverLogger: transportLogger,
  );

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

abstract interface class IMainServiceContract implements IRpcContract {
  Future<RpcString> getMessage(RpcString message);
}

/// Основной контракт сервиса
final class MainServiceContract extends RpcResponderContract
    implements IMainServiceContract {
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
      handler: getMessage,
      requestCodec: RpcString.codec,
      responseCodec: RpcString.codec,
      description: 'Получает сообщение',
    );
  }

  @override
  Future<RpcString> getMessage(RpcString message) async {
    final logger = RpcLogger('MainServiceHandler');
    logger.info('Получен запрос: ${message.value}');

    final response = RpcString('Вы отправили: ${message.value}');
    logger.info('Отправляем ответ: ${response.value}');
    return response;
  }
}

abstract interface class IUserServiceContract implements IRpcContract {
  Future<UserResponse> getUser(RpcInt id);
}

/// Подконтракт для работы с пользователями
final class UserServiceContract extends RpcResponderContract
    implements IUserServiceContract {
  UserServiceContract() : super('UserService');

  @override
  void setup() {
    // Регистрируем методы подконтракта пользователей
    addUnaryMethod<RpcInt, UserResponse>(
      methodName: 'GetUser',
      handler: getUser,
      requestCodec: RpcInt.codec,
      responseCodec: RpcCodec(UserResponse.fromJson),
      description: 'Получает информацию о пользователе по ID',
    );
  }

  @override
  Future<UserResponse> getUser(RpcInt id) async {
    final logger = RpcLogger('UserServiceHandler');
    final idValue = id.value;
    logger.info('Получен запрос на информацию о пользователе $idValue');

    // Имитируем получение данных из БД
    final response = UserResponse(id: idValue, name: 'Пользователь #$idValue');

    logger.info('Возвращаем информацию о пользователе: $response');
    return response;
  }
}

abstract interface class INotificationServiceContract implements IRpcContract {
  Future<RpcBool> sendNotification(RpcString message);
}

/// Подконтракт для отправки уведомлений
final class NotificationServiceContract extends RpcResponderContract
    implements INotificationServiceContract {
  NotificationServiceContract() : super('NotificationService');

  @override
  void setup() {
    // Регистрируем методы подконтракта уведомлений
    addUnaryMethod<RpcString, RpcBool>(
      methodName: 'SendNotification',
      handler: sendNotification,
      requestCodec: RpcString.codec,
      responseCodec: RpcBool.codec,
      description: 'Отправляет уведомление',
    );
  }

  @override
  Future<RpcBool> sendNotification(RpcString message) async {
    final logger = RpcLogger('NotificationServiceHandler');
    logger.info('Отправка уведомления: ${message.value}');
    return const RpcBool(true);
  }
}

//
// КЛИЕНТСКИЕ КОНТРАКТЫ
//

/// Основной клиентский контракт
final class MainServiceCallerContract extends RpcCallerContract
    implements IMainServiceContract {
  final UserServiceCallerContract user;
  final NotificationServiceCallerContract notification;

  MainServiceCallerContract(RpcCallerEndpoint endpoint)
      : user = UserServiceCallerContract(endpoint),
        notification = NotificationServiceCallerContract(endpoint),
        super('MainService', endpoint);

  @override
  Future<RpcString> getMessage(RpcString message) async {
    return await endpoint.unaryRequest<RpcString, RpcString>(
      serviceName: serviceName,
      methodName: 'GetMessage',
      requestCodec: RpcString.codec,
      responseCodec: RpcString.codec,
      request: message,
    );
  }
}

/// Клиентский подконтракт для работы с пользователями
final class UserServiceCallerContract extends RpcCallerContract
    implements IUserServiceContract {
  UserServiceCallerContract(RpcCallerEndpoint endpoint)
      : super('UserService', endpoint);

  /// Получает информацию о пользователе по ID
  @override
  Future<UserResponse> getUser(RpcInt userId) async {
    return await endpoint.unaryRequest<RpcInt, UserResponse>(
      serviceName: serviceName,
      methodName: 'GetUser',
      requestCodec: RpcInt.codec,
      responseCodec: RpcCodec(UserResponse.fromJson),
      request: userId,
    );
  }
}

/// Клиентский подконтракт для отправки уведомлений
final class NotificationServiceCallerContract extends RpcCallerContract
    implements INotificationServiceContract {
  NotificationServiceCallerContract(RpcCallerEndpoint endpoint)
      : super('NotificationService', endpoint);

  /// Отправляет уведомление
  @override
  Future<RpcBool> sendNotification(RpcString message) async {
    return await endpoint.unaryRequest<RpcString, RpcBool>(
      serviceName: serviceName,
      methodName: 'SendNotification',
      requestCodec: RpcString.codec,
      responseCodec: RpcBool.codec,
      request: message,
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
