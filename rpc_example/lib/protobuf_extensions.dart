// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: LGPL-3.0-or-later

/// 🔧 Расширения для интеграции protobuf классов с RPC библиотекой
///
/// Этот файл показывает как пользователи могут интегрировать
/// сгенерированные protobuf классы с IRpcSerializableMessage
library;

import 'dart:typed_data';
import 'package:fixnum/fixnum.dart';
import 'package:protobuf/protobuf.dart';
import 'package:rpc_dart/contracts/base.dart';

import 'generated/user_service.pb.dart';

/// ============================================
/// РАСШИРЕНИЯ ДЛЯ ПРОТОБУФ КЛАССОВ
/// ============================================

/// Базовое расширение для всех protobuf сообщений
extension ProtobufRpcExtension<T extends GeneratedMessage> on T {
  /// Прямая интеграция с IRpcSerializableMessage через protobuf бинарный формат
  Uint8List toBuffer() {
    // Используем встроенную бинарную сериализацию protobuf
    return Uint8List.fromList(writeToBuffer());
  }
}

/// ============================================
/// ОБЕРТКИ ДЛЯ СОВМЕСТИМОСТИ С RPC
/// ============================================

/// Обертка для GetUserRequest
class RpcGetUserRequest implements IRpcSerializableMessage {
  final GetUserRequest _proto;

  RpcGetUserRequest(this._proto);

  factory RpcGetUserRequest.create({
    required int userId,
    bool includeTags = false,
  }) {
    return RpcGetUserRequest(GetUserRequest()
      ..userId = userId
      ..includeTags = includeTags);
  }

  @override
  Uint8List toBuffer() => _proto.toBuffer();

  static RpcGetUserRequest fromBuffer(Uint8List bytes) {
    final proto = GetUserRequest.fromBuffer(bytes);
    return RpcGetUserRequest(proto);
  }

  // Геттеры для удобства
  int get userId => _proto.userId;
  bool get includeTags => _proto.includeTags;

  GetUserRequest get proto => _proto;
}

/// Обертка для GetUserResponse
class RpcGetUserResponse implements IRpcSerializableMessage {
  final GetUserResponse _proto;

  RpcGetUserResponse(this._proto);

  factory RpcGetUserResponse.create({
    User? user,
    bool success = true,
    String errorMessage = '',
  }) {
    return RpcGetUserResponse(
      GetUserResponse()
        ..user = user ?? User()
        ..success = success
        ..errorMessage = errorMessage,
    );
  }

  @override
  Uint8List toBuffer() => _proto.toBuffer();

  static RpcGetUserResponse fromBuffer(Uint8List bytes) {
    final proto = GetUserResponse.fromBuffer(bytes);
    return RpcGetUserResponse(proto);
  }

  // Геттеры для удобства
  User? get user => _proto.hasUser() ? _proto.user : null;
  bool get success => _proto.success;
  String get errorMessage => _proto.errorMessage;

  GetUserResponse get proto => _proto;
}

/// Обертка для CreateUserRequest
class RpcCreateUserRequest implements IRpcSerializableMessage {
  final CreateUserRequest _proto;

  RpcCreateUserRequest(this._proto);

  factory RpcCreateUserRequest.create({
    required String name,
    required String email,
    List<String> tags = const [],
  }) {
    return RpcCreateUserRequest(CreateUserRequest()
      ..name = name
      ..email = email
      ..tags.addAll(tags));
  }

  @override
  Uint8List toBuffer() => _proto.toBuffer();

  static RpcCreateUserRequest fromBuffer(Uint8List bytes) {
    final proto = CreateUserRequest.fromBuffer(bytes);
    return RpcCreateUserRequest(proto);
  }

  // Геттеры для удобства
  String get name => _proto.name;
  String get email => _proto.email;
  List<String> get tags => _proto.tags.toList();

  CreateUserRequest get proto => _proto;
}

/// Обертка для CreateUserResponse
class RpcCreateUserResponse implements IRpcSerializableMessage {
  final CreateUserResponse _proto;

  RpcCreateUserResponse(this._proto);

  factory RpcCreateUserResponse.create({
    User? user,
    bool success = true,
    String errorMessage = '',
  }) {
    return RpcCreateUserResponse(
      CreateUserResponse()
        ..user = user ?? User()
        ..success = success
        ..errorMessage = errorMessage,
    );
  }

  @override
  Uint8List toBuffer() => _proto.toBuffer();

  static RpcCreateUserResponse fromBuffer(Uint8List bytes) {
    final proto = CreateUserResponse.fromBuffer(bytes);
    return RpcCreateUserResponse(proto);
  }

  // Геттеры для удобства
  User? get user => _proto.hasUser() ? _proto.user : null;
  bool get success => _proto.success;
  String get errorMessage => _proto.errorMessage;

  CreateUserResponse get proto => _proto;
}

/// Обертка для ListUsersRequest
class RpcListUsersRequest implements IRpcSerializableMessage {
  final ListUsersRequest _proto;

  RpcListUsersRequest(this._proto);

  factory RpcListUsersRequest.create({
    int limit = 10,
    int offset = 0,
    UserStatus statusFilter = UserStatus.UNKNOWN,
  }) {
    return RpcListUsersRequest(ListUsersRequest()
      ..limit = limit
      ..offset = offset
      ..statusFilter = statusFilter);
  }

  @override
  Uint8List toBuffer() => _proto.toBuffer();

  static RpcListUsersRequest fromBuffer(Uint8List bytes) {
    final proto = ListUsersRequest.fromBuffer(bytes);
    return RpcListUsersRequest(proto);
  }

  // Геттеры для удобства
  int get limit => _proto.limit;
  int get offset => _proto.offset;
  UserStatus get statusFilter => _proto.statusFilter;

  ListUsersRequest get proto => _proto;
}

/// Обертка для ListUsersResponse
class RpcListUsersResponse implements IRpcSerializableMessage {
  final ListUsersResponse _proto;

  RpcListUsersResponse(this._proto);

  factory RpcListUsersResponse.create({
    List<User> users = const [],
    bool hasMore = false,
    bool success = true,
  }) {
    return RpcListUsersResponse(
      ListUsersResponse()
        ..users.addAll(users)
        ..hasMore = hasMore,
    );
  }

  @override
  Uint8List toBuffer() => _proto.toBuffer();

  static RpcListUsersResponse fromBuffer(Uint8List bytes) {
    final proto = ListUsersResponse.fromBuffer(bytes);
    return RpcListUsersResponse(proto);
  }

  // Геттеры для удобства
  List<User> get users => _proto.users.toList();
  bool get hasMore => _proto.hasMore;
  bool get success => true; // Всегда true для упрощения

  ListUsersResponse get proto => _proto;
}

/// Обертка для WatchUsersRequest
class RpcWatchUsersRequest implements IRpcSerializableMessage {
  final WatchUsersRequest _proto;

  RpcWatchUsersRequest(this._proto);

  factory RpcWatchUsersRequest.create({
    required List<int> userIds,
    List<String> eventTypes = const [],
  }) {
    return RpcWatchUsersRequest(WatchUsersRequest()
      ..userIds.addAll(userIds)
      ..eventTypes.addAll(eventTypes));
  }

  @override
  Uint8List toBuffer() => _proto.toBuffer();

  static RpcWatchUsersRequest fromBuffer(Uint8List bytes) {
    final proto = WatchUsersRequest.fromBuffer(bytes);
    return RpcWatchUsersRequest(proto);
  }

  // Геттеры для удобства
  List<int> get userIds => _proto.userIds.toList();
  List<String> get eventTypes => _proto.eventTypes.toList();

  WatchUsersRequest get proto => _proto;
}

/// Обертка для UserEventResponse
class RpcUserEventResponse implements IRpcSerializableMessage {
  final UserEventResponse _proto;

  RpcUserEventResponse(this._proto);

  factory RpcUserEventResponse.create({
    UserEvent? event,
    bool success = true,
  }) {
    return RpcUserEventResponse(
      UserEventResponse()..event = event ?? UserEvent(),
    );
  }

  @override
  Uint8List toBuffer() => _proto.toBuffer();

  static RpcUserEventResponse fromBuffer(Uint8List bytes) {
    final proto = UserEventResponse.fromBuffer(bytes);
    return RpcUserEventResponse(proto);
  }

  // Геттеры для удобства
  UserEvent get event => _proto.event;
  bool get success => true; // Всегда true для упрощения

  UserEventResponse get proto => _proto;
}

/// Обертка для BatchCreateUsersResponse
class RpcBatchCreateUsersResponse implements IRpcSerializableMessage {
  final BatchCreateUsersResponse _proto;

  RpcBatchCreateUsersResponse(this._proto);

  factory RpcBatchCreateUsersResponse.create({
    List<User> users = const [],
    int totalCreated = 0,
    int totalErrors = 0,
    List<String> errorMessages = const [],
    bool success = true,
  }) {
    return RpcBatchCreateUsersResponse(
      BatchCreateUsersResponse()
        ..users.addAll(users)
        ..totalCreated = totalCreated
        ..totalErrors = totalErrors
        ..errorMessages.addAll(errorMessages)
        ..success = success,
    );
  }

  @override
  Uint8List toBuffer() => _proto.toBuffer();

  static RpcBatchCreateUsersResponse fromBuffer(Uint8List bytes) {
    final proto = BatchCreateUsersResponse.fromBuffer(bytes);
    return RpcBatchCreateUsersResponse(proto);
  }

  // Геттеры для удобства
  List<User> get users => _proto.users.toList();
  int get totalCreated => _proto.totalCreated;
  int get totalErrors => _proto.totalErrors;
  List<String> get errorMessages => _proto.errorMessages.toList();
  bool get success => _proto.success;

  BatchCreateUsersResponse get proto => _proto;
}

/// ============================================
/// УТИЛИТЫ ДЛЯ СОЗДАНИЯ ПРОТОБУФ ОБЪЕКТОВ
/// ============================================

/// Утилиты для создания protobuf объектов
class ProtoUtils {
  /// Создает пользователя
  static User createUser({
    required int id,
    required String name,
    required String email,
    List<String> tags = const [],
    UserStatus status = UserStatus.ACTIVE,
    DateTime? createdAt,
  }) {
    final timestamp = createdAt?.millisecondsSinceEpoch ?? DateTime.now().millisecondsSinceEpoch;

    return User()
      ..id = id
      ..name = name
      ..email = email
      ..tags.addAll(tags)
      ..status = status
      ..createdAt = Int64(timestamp);
  }

  /// Создает событие пользователя
  static UserEvent createUserEvent({
    required int userId,
    required String eventType,
    Map<String, String> data = const {},
    DateTime? timestamp,
  }) {
    final eventTimestamp =
        timestamp?.millisecondsSinceEpoch ?? DateTime.now().millisecondsSinceEpoch;

    return UserEvent()
      ..userId = userId
      ..eventType = eventType
      ..data.addAll(data)
      ..timestamp = Int64(eventTimestamp);
  }
}

/// ============================================
/// УТИЛИТЫ ДЛЯ ПРОТОБУФ
/// ============================================

/// Утилитарный класс для создания protobuf сериализаторов
class ProtobufSerializers {
  /// Создает сериализатор для RpcGetUserRequest
  static RpcGetUserRequest Function(Uint8List) getUserRequestParser() {
    return RpcGetUserRequest.fromBuffer;
  }

  /// Создает сериализатор для RpcGetUserResponse
  static RpcGetUserResponse Function(Uint8List) getUserResponseParser() {
    return RpcGetUserResponse.fromBuffer;
  }

  /// Создает сериализатор для RpcCreateUserRequest
  static RpcCreateUserRequest Function(Uint8List) createUserRequestParser() {
    return RpcCreateUserRequest.fromBuffer;
  }

  /// Создает сериализатор для RpcCreateUserResponse
  static RpcCreateUserResponse Function(Uint8List) createUserResponseParser() {
    return RpcCreateUserResponse.fromBuffer;
  }

  /// Создает сериализатор для RpcListUsersRequest
  static RpcListUsersRequest Function(Uint8List) listUsersRequestParser() {
    return RpcListUsersRequest.fromBuffer;
  }

  /// Создает сериализатор для RpcListUsersResponse
  static RpcListUsersResponse Function(Uint8List) listUsersResponseParser() {
    return RpcListUsersResponse.fromBuffer;
  }

  /// Создает сериализатор для RpcWatchUsersRequest
  static RpcWatchUsersRequest Function(Uint8List) watchUsersRequestParser() {
    return RpcWatchUsersRequest.fromBuffer;
  }

  /// Создает сериализатор для RpcUserEventResponse
  static RpcUserEventResponse Function(Uint8List) userEventResponseParser() {
    return RpcUserEventResponse.fromBuffer;
  }

  /// Создает сериализатор для RpcBatchCreateUsersResponse
  static RpcBatchCreateUsersResponse Function(Uint8List) batchCreateUsersResponseParser() {
    return RpcBatchCreateUsersResponse.fromBuffer;
  }
}
