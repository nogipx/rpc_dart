// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: LGPL-3.0-or-later

/// 🎯 Пример контракта пользовательского сервиса с protobuf

import 'dart:async';
import 'package:fixnum/fixnum.dart';
import 'package:rpc_dart/contracts/base.dart';
import 'package:rpc_dart/contracts/rpc_service_contract.dart';
import 'package:rpc_dart/rpc/_index.dart';
import 'package:rpc_dart/logger.dart';

import 'generated/user_service.pb.dart';
import 'protobuf_extensions.dart';

/// Контракт пользовательского сервиса с использованием protobuf типов
abstract class ProtobufUserServiceContract extends RpcServiceContract {
  static const methodGetUser = 'getUser';
  static const methodCreateUser = 'createUser';
  static const methodBatchCreateUsers = 'batchCreateUsers';
  static const methodListUsers = 'listUsers';
  static const methodWatchUsers = 'watchUsers';

  ProtobufUserServiceContract() : super('ProtobufUserService');

  @override
  void setup() {
    // Унарные методы
    addUnaryMethod<RpcGetUserRequest, RpcGetUserResponse>(
      methodName: methodGetUser,
      handler: getUser,
      description: 'Получает пользователя по ID (protobuf)',
      metadata: const RpcMethodMetadata(
        timeout: Duration(seconds: 5),
        cacheable: true,
      ),
    );

    addUnaryMethod<RpcCreateUserRequest, RpcCreateUserResponse>(
      methodName: methodCreateUser,
      handler: createUser,
      description: 'Создает нового пользователя (protobuf)',
      metadata: const RpcMethodMetadata(
        requiresAuth: true,
        permissions: ['user.create'],
      ),
    );

    // Клиентский стрим
    addClientStreamMethod<RpcCreateUserRequest, RpcBatchCreateUsersResponse>(
      methodName: methodBatchCreateUsers,
      handler: batchCreateUsers,
      description: 'Создает множество пользователей через поток (protobuf)',
      metadata: const RpcMethodMetadata(
        requiresAuth: true,
        permissions: ['user.batch_create'],
        timeout: Duration(seconds: 60),
      ),
    );

    // Серверный стрим
    addServerStreamMethod<RpcListUsersRequest, RpcListUsersResponse>(
      methodName: methodListUsers,
      handler: listUsers,
      description: 'Получает список пользователей потоком (protobuf)',
      metadata: const RpcMethodMetadata(
        timeout: Duration(seconds: 30),
      ),
    );

    // Двунаправленный стрим
    addBidirectionalMethod<RpcWatchUsersRequest, RpcUserEventResponse>(
      methodName: methodWatchUsers,
      handler: watchUsers,
      description: 'Наблюдает за изменениями пользователей (protobuf)',
      metadata: const RpcMethodMetadata(
        requiresAuth: true,
        permissions: ['user.watch'],
        timeout: Duration(minutes: 30),
      ),
    );

    super.setup();
  }

  /// Получает пользователя по ID
  Future<RpcGetUserResponse> getUser(RpcGetUserRequest request);

  /// Создает нового пользователя
  Future<RpcCreateUserResponse> createUser(RpcCreateUserRequest request);

  /// Создает множество пользователей через клиентский стрим
  Future<RpcBatchCreateUsersResponse> batchCreateUsers(Stream<RpcCreateUserRequest> requests);

  /// Получает список пользователей потоком
  Stream<RpcListUsersResponse> listUsers(RpcListUsersRequest request);

  /// Наблюдает за изменениями пользователей
  Stream<RpcUserEventResponse> watchUsers(Stream<RpcWatchUsersRequest> requests);
}

/// Клиент пользовательского сервиса с protobuf
class ProtobufUserServiceClient extends ProtobufUserServiceContract {
  final RpcEndpoint _endpoint;

  ProtobufUserServiceClient(this._endpoint);

  @override
  Future<RpcGetUserResponse> getUser(RpcGetUserRequest request) {
    return _endpoint
        .unaryRequest(
          serviceName: serviceName,
          methodName: ProtobufUserServiceContract.methodGetUser,
        )
        .call(
          request: request,
          responseParser: ProtobufSerializers.getUserResponseParser(),
        );
  }

  @override
  Future<RpcCreateUserResponse> createUser(RpcCreateUserRequest request) {
    return _endpoint
        .unaryRequest(
          serviceName: serviceName,
          methodName: ProtobufUserServiceContract.methodCreateUser,
        )
        .call(
          request: request,
          responseParser: ProtobufSerializers.createUserResponseParser(),
        );
  }

  @override
  Future<RpcBatchCreateUsersResponse> batchCreateUsers(Stream<RpcCreateUserRequest> requests) {
    return _endpoint
        .clientStream(
          serviceName: serviceName,
          methodName: ProtobufUserServiceContract.methodBatchCreateUsers,
        )
        .call(
          requests: requests,
          responseParser: ProtobufSerializers.batchCreateUsersResponseParser(),
        );
  }

  @override
  Stream<RpcListUsersResponse> listUsers(RpcListUsersRequest request) {
    return _endpoint
        .serverStream(
          serviceName: serviceName,
          methodName: ProtobufUserServiceContract.methodListUsers,
        )
        .call(
          request: request,
          responseParser: ProtobufSerializers.listUsersResponseParser(),
        );
  }

  @override
  Stream<RpcUserEventResponse> watchUsers(Stream<RpcWatchUsersRequest> requests) {
    return _endpoint
        .bidirectionalStream(
          serviceName: serviceName,
          methodName: ProtobufUserServiceContract.methodWatchUsers,
        )
        .call(
          requests: requests,
          responseParser: ProtobufSerializers.userEventResponseParser(),
        );
  }
}

/// Сервер пользовательского сервиса с protobuf
class ProtobufUserServiceServer extends ProtobufUserServiceContract {
  // Простая база данных в памяти для демонстрации
  final Map<int, User> _users = {};
  int _nextId = 1;

  @override
  Future<RpcGetUserResponse> getUser(RpcGetUserRequest request) async {
    print('   📥 ProtobufServer: Получен запрос getUser(${request.userId})');

    final user = _users[request.userId];
    if (user == null) {
      return RpcGetUserResponse.create(
        success: false,
        errorMessage: 'Пользователь с ID ${request.userId} не найден',
      );
    }

    return RpcGetUserResponse.create(
      user: user,
      success: true,
    );
  }

  @override
  Future<RpcCreateUserResponse> createUser(RpcCreateUserRequest request) async {
    print('   📥 ProtobufServer: Получен запрос createUser(${request.name})');

    // Валидация
    if (request.name.trim().isEmpty) {
      return RpcCreateUserResponse.create(
        success: false,
        errorMessage: 'Имя пользователя не может быть пустым',
      );
    }

    if (!request.email.contains('@')) {
      return RpcCreateUserResponse.create(
        success: false,
        errorMessage: 'Некорректный формат email',
      );
    }

    // Создаем пользователя
    final user = User()
      ..id = _nextId++
      ..name = request.name
      ..email = request.email
      ..tags.addAll(request.tags)
      ..status = UserStatus.ACTIVE
      ..createdAt = Int64(DateTime.now().millisecondsSinceEpoch);

    _users[user.id] = user;

    return RpcCreateUserResponse.create(
      user: user,
      success: true,
    );
  }

  @override
  Future<RpcBatchCreateUsersResponse> batchCreateUsers(
      Stream<RpcCreateUserRequest> requests) async {
    print('   📥 ProtobufServer: Получен поток запросов batchCreateUsers');

    final createdUsers = <User>[];
    final errors = <String>[];
    var totalProcessed = 0;

    await for (final request in requests) {
      totalProcessed++;
      print('   🔄 Обрабатываем пользователя ${totalProcessed}: ${request.name}');

      // Валидация
      if (request.name.trim().isEmpty) {
        errors.add('Пользователь #$totalProcessed: Имя не может быть пустым');
        continue;
      }

      if (!request.email.contains('@')) {
        errors.add('Пользователь #$totalProcessed: Некорректный email "${request.email}"');
        continue;
      }

      // Создаем пользователя
      final user = User()
        ..id = _nextId++
        ..name = request.name
        ..email = request.email
        ..tags.addAll(request.tags)
        ..status = UserStatus.ACTIVE
        ..createdAt = Int64(DateTime.now().millisecondsSinceEpoch);

      _users[user.id] = user;
      createdUsers.add(user);

      // Имитируем задержку обработки
      await Future.delayed(Duration(milliseconds: 50));
    }

    print(
        '   ✅ ProtobufServer: Обработка завершена. Создано: ${createdUsers.length}, ошибок: ${errors.length}');

    return RpcBatchCreateUsersResponse.create(
      users: createdUsers,
      totalCreated: createdUsers.length,
      totalErrors: errors.length,
      errorMessages: errors,
      success: errors.isEmpty,
    );
  }

  @override
  Stream<RpcListUsersResponse> listUsers(RpcListUsersRequest request) async* {
    print(
        '   📥 ProtobufServer: Получен запрос listUsers(limit: ${request.limit}, offset: ${request.offset})');

    final allUsers = _users.values.toList();
    final filteredUsers = request.statusFilter != UserStatus.UNKNOWN
        ? allUsers.where((user) => user.status == request.statusFilter).toList()
        : allUsers;

    // Сортируем по ID для стабильности
    filteredUsers.sort((a, b) => a.id.compareTo(b.id));

    final startIndex = request.offset;
    final endIndex = (startIndex + request.limit).clamp(0, filteredUsers.length);

    for (int i = startIndex; i < endIndex; i++) {
      final user = filteredUsers[i];
      final hasMore = i < filteredUsers.length - 1;

      print('   📤 Отправляем пользователя: ${user.name} (${i + 1}/${filteredUsers.length})');

      yield RpcListUsersResponse.create(
        users: [user],
        hasMore: hasMore,
        success: true,
      );

      // Имитируем задержку между элементами стрима
      await Future.delayed(Duration(milliseconds: 100));
    }

    print('   ✅ ProtobufServer: listUsers завершен');
  }

  @override
  Stream<RpcUserEventResponse> watchUsers(Stream<RpcWatchUsersRequest> requests) async* {
    print('   📥 ProtobufServer: Запущен watchUsers');

    await for (final request in requests) {
      print('   📡 Наблюдаем за пользователями: ${request.userIds}');

      // Генерируем события для каждого пользователя
      for (final userId in request.userIds) {
        // Фильтруем по типам событий если указаны
        final eventTypes = request.eventTypes.isEmpty
            ? ['USER_ACTIVITY', 'USER_UPDATE', 'USER_STATUS_CHANGE']
            : request.eventTypes;

        for (final eventType in eventTypes) {
          final event = UserEvent()
            ..userId = userId
            ..eventType = eventType
            ..data.addAll(_generateEventData(eventType, userId))
            ..timestamp = Int64(DateTime.now().millisecondsSinceEpoch);

          print('   📤 Отправляем событие: $eventType для пользователя $userId');

          yield RpcUserEventResponse.create(
            event: event,
            success: true,
          );

          // Задержка между событиями
          await Future.delayed(Duration(milliseconds: 200));
        }
      }
    }

    print('   ✅ ProtobufServer: watchUsers завершен');
  }

  /// Генерирует данные события в зависимости от типа
  Map<String, String> _generateEventData(String eventType, int userId) {
    switch (eventType) {
      case 'USER_ACTIVITY':
        return {
          'action': 'login',
          'timestamp': DateTime.now().toIso8601String(),
          'ip_address': '192.168.1.${userId % 255}'
        };
      case 'USER_UPDATE':
        return {
          'field': 'last_seen',
          'old_value': DateTime.now().subtract(Duration(hours: 1)).toIso8601String(),
          'new_value': DateTime.now().toIso8601String()
        };
      case 'USER_STATUS_CHANGE':
        return {'old_status': 'INACTIVE', 'new_status': 'ACTIVE', 'reason': 'user_login'};
      default:
        return {
          'event_type': eventType,
          'user_id': userId.toString(),
          'timestamp': DateTime.now().toIso8601String()
        };
    }
  }

  /// Добавляет тестовых пользователей для демонстрации
  void addTestUsers() {
    final testUsers = [
      User()
        ..id = _nextId++
        ..name = 'Алиса'
        ..email = 'alice@example.com'
        ..tags.addAll(['admin', 'developer'])
        ..status = UserStatus.ACTIVE
        ..createdAt = Int64(DateTime.now().subtract(Duration(days: 10)).millisecondsSinceEpoch),
      User()
        ..id = _nextId++
        ..name = 'Боб'
        ..email = 'bob@example.com'
        ..tags.addAll(['user', 'tester'])
        ..status = UserStatus.ACTIVE
        ..createdAt = Int64(DateTime.now().subtract(Duration(days: 5)).millisecondsSinceEpoch),
      User()
        ..id = _nextId++
        ..name = 'Клэр'
        ..email = 'claire@example.com'
        ..tags.addAll(['manager', 'analyst'])
        ..status = UserStatus.INACTIVE
        ..createdAt = Int64(DateTime.now().subtract(Duration(days: 1)).millisecondsSinceEpoch),
    ];

    for (final user in testUsers) {
      _users[user.id] = user;
    }

    print('   🔧 Добавлено ${testUsers.length} тестовых пользователей');
  }

  /// Настраивает серверные обработчики вручную (обходим автоматическую регистрацию)
  Future<void> setupServers(IRpcTransport transport, RpcLogger logger) async {
    // Унарные серверы
    final getUserServer = UnaryServer<RpcGetUserRequest, RpcGetUserResponse>(
      transport: transport,
      serviceName: serviceName,
      methodName: ProtobufUserServiceContract.methodGetUser,
      requestSerializer: RpcBytesSerializer<RpcGetUserRequest>(
        fromBuffer: ProtobufSerializers.getUserRequestParser(),
      ),
      responseSerializer: RpcBytesSerializer<RpcGetUserResponse>(
        fromBuffer: (bytes) =>
            throw UnsupportedError('Response deserialization not needed on server'),
      ),
      handler: getUser,
      logger: logger,
    );

    final createUserServer = UnaryServer<RpcCreateUserRequest, RpcCreateUserResponse>(
      transport: transport,
      serviceName: serviceName,
      methodName: ProtobufUserServiceContract.methodCreateUser,
      requestSerializer: RpcBytesSerializer<RpcCreateUserRequest>(
        fromBuffer: ProtobufSerializers.createUserRequestParser(),
      ),
      responseSerializer: RpcBytesSerializer<RpcCreateUserResponse>(
        fromBuffer: (bytes) =>
            throw UnsupportedError('Response deserialization not needed on server'),
      ),
      handler: createUser,
      logger: logger,
    );

    // Клиентский стрим сервер
    final batchCreateServer = ClientStreamServer<RpcCreateUserRequest, RpcBatchCreateUsersResponse>(
      transport: transport,
      serviceName: serviceName,
      methodName: ProtobufUserServiceContract.methodBatchCreateUsers,
      requestSerializer: RpcBytesSerializer<RpcCreateUserRequest>(
        fromBuffer: ProtobufSerializers.createUserRequestParser(),
      ),
      responseSerializer: RpcBytesSerializer<RpcBatchCreateUsersResponse>(
        fromBuffer: (bytes) =>
            throw UnsupportedError('Response deserialization not needed on server'),
      ),
      handler: batchCreateUsers,
      logger: logger,
    );

    // Серверный стрим сервер
    final listUsersServer = ServerStreamServer<RpcListUsersRequest, RpcListUsersResponse>(
      transport: transport,
      serviceName: serviceName,
      methodName: ProtobufUserServiceContract.methodListUsers,
      requestSerializer: RpcBytesSerializer<RpcListUsersRequest>(
        fromBuffer: ProtobufSerializers.listUsersRequestParser(),
      ),
      responseSerializer: RpcBytesSerializer<RpcListUsersResponse>(
        fromBuffer: (bytes) =>
            throw UnsupportedError('Response deserialization not needed on server'),
      ),
      handler: (request, responder) async {
        try {
          final responseStream = listUsers(request);
          await for (final response in responseStream) {
            await responder.send(response);
          }
          await responder.complete();
        } catch (e) {
          await responder.completeWithError(RpcStatus.INTERNAL, e.toString());
        }
      },
      logger: logger,
    );

    // Двунаправленный стрим сервер
    final watchUsersServer = BidirectionalStreamServer<RpcWatchUsersRequest, RpcUserEventResponse>(
      transport: transport,
      serviceName: serviceName,
      methodName: ProtobufUserServiceContract.methodWatchUsers,
      requestSerializer: RpcBytesSerializer<RpcWatchUsersRequest>(
        fromBuffer: ProtobufSerializers.watchUsersRequestParser(),
      ),
      responseSerializer: RpcBytesSerializer<RpcUserEventResponse>(
        fromBuffer: (bytes) =>
            throw UnsupportedError('Response deserialization not needed on server'),
      ),
      logger: logger,
    );

    // Настраиваем обработку запросов для bidirectional
    watchUsersServer.requests.listen((request) async {
      try {
        // Создаем контроллер для единичного запроса
        final requestController = StreamController<RpcWatchUsersRequest>();
        requestController.add(request);
        final responseStream = watchUsers(requestController.stream);

        await for (final response in responseStream) {
          await watchUsersServer.send(response);
        }

        await requestController.close();
      } catch (e) {
        logger.error('Ошибка в bidirectional handler: $e');
      }
    });

    logger.info('Серверы настроены для ProtobufUserService');
  }

  /// Закрывает все серверные обработчики
  Future<void> closeServers() async {
    // В реальной реализации здесь была бы логика закрытия серверов
    print('   🔧 Серверы ProtobufUserService закрыты');
  }
}
