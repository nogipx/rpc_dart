# Интеграция Protobuf с RPC Dart

Руководство по интеграции Protocol Buffers (protobuf) с RPC Dart библиотекой для создания типобезопасных и высокопроизводительных RPC сервисов.

## Содержание

1. [Быстрый старт](#быстрый-старт)
2. [Установка и настройка](#установка-и-настройка)
3. [Создание .proto файлов](#создание-proto-файлов)
4. [Генерация Dart кода](#генерация-dart-кода)
5. [Создание wrapper классов](#создание-wrapper-классов)
6. [Реализация сервисов](#реализация-сервисов)
7. [Примеры RPC типов](#примеры-rpc-типов)
8. [Best Practices](#best-practices)

## Быстрый старт

### 1. Создайте .proto файл

```protobuf
// user_service.proto
syntax = "proto3";

package user_service;

// Унарные методы
message GetUserRequest {
  int32 user_id = 1;
  bool include_tags = 2;
}

message CreateUserRequest {
  string name = 1;
  string email = 2;
  repeated string tags = 3;
}

message UserResponse {
  User user = 1;
  bool success = 2;
  string error_message = 3;
}

// Сообщения для стримов
message ListUsersRequest {
  int32 limit = 1;
  int32 offset = 2;
  UserStatus status_filter = 3;
}

message BatchCreateUsersResponse {
  repeated User users = 1;
  int32 total_created = 2;
  int32 total_errors = 3;
  repeated string error_messages = 4;
  bool success = 5;
}

// Основные типы
message User {
  int32 id = 1;
  string name = 2;
  string email = 3;
  repeated string tags = 4;
  UserStatus status = 5;
  int64 created_at = 6;
}

enum UserStatus {
  UNKNOWN = 0;
  ACTIVE = 1;
  INACTIVE = 2;
  SUSPENDED = 3;
}
```

### 2. Сгенерируйте Dart код

```bash
protoc --dart_out=../lib/generated user_service.proto
```

### 3. Создайте wrapper классы

```dart
// protobuf_extensions.dart
import 'package:rpc_dart/contracts/base.dart';
import 'generated/user_service.pb.dart';

class RpcCreateUserRequest implements IRpcSerializableMessage {
  final CreateUserRequest _proto;

  RpcCreateUserRequest(this._proto);

  factory RpcCreateUserRequest.create({
    required String name,
    required String email,
    List<String> tags = const [],
  }) {
    final proto = CreateUserRequest()
      ..name = name
      ..email = email
      ..tags.addAll(tags);
    return RpcCreateUserRequest(proto);
  }

  // Геттеры для удобного доступа
  String get name => _proto.name;
  String get email => _proto.email;
  List<String> get tags => _proto.tags;

  @override
  Map<String, dynamic> toJson() {
    return {
      'name': _proto.name,
      'email': _proto.email,
      'tags': _proto.tags,
    };
  }

  static RpcCreateUserRequest fromJson(Map<String, dynamic> json) {
    final proto = CreateUserRequest()
      ..name = json['name'] ?? ''
      ..email = json['email'] ?? ''
      ..tags.addAll(List<String>.from(json['tags'] ?? []));
    return RpcCreateUserRequest(proto);
  }
}
```

### 4. Реализуйте сервис

```dart
// protobuf_user_service.dart
abstract class ProtobufUserServiceContract extends RpcServiceContract {
  ProtobufUserServiceContract() : super('ProtobufUserService');

  @override
  void setup() {
    // Унарные методы
    addUnaryMethod<RpcGetUserRequest, RpcGetUserResponse>(
      methodName: 'getUser',
      handler: getUser,
    );

    addUnaryMethod<RpcCreateUserRequest, RpcCreateUserResponse>(
      methodName: 'createUser', 
      handler: createUser,
    );

    // Клиентский стрим
    addClientStreamMethod<RpcCreateUserRequest, RpcBatchCreateUsersResponse>(
      methodName: 'batchCreateUsers',
      handler: batchCreateUsers,
    );

    super.setup();
  }

  // Абстрактные методы
  Future<RpcGetUserResponse> getUser(RpcGetUserRequest request);
  Future<RpcCreateUserResponse> createUser(RpcCreateUserRequest request);
  Future<RpcBatchCreateUsersResponse> batchCreateUsers(Stream<RpcCreateUserRequest> requests);
}
```

## Установка и настройка

### Установка protoc

**macOS:**
```bash
brew install protobuf
```

**Ubuntu/Debian:**
```bash
sudo apt-get install protobuf-compiler
```

**Windows:**
Скачайте с [GitHub Releases](https://github.com/protocolbuffers/protobuf/releases)

### Установка Dart плагина

```bash
dart pub global activate protoc_plugin
```

### Добавление зависимостей

В `pubspec.yaml`:

```yaml
dependencies:
  protobuf: ^3.1.0
  rpc_dart: ^1.0.0

dev_dependencies:
  protoc_plugin: ^21.1.2
```

## Создание .proto файлов

### Структура проекта

```
your_project/
├── protos/           # .proto файлы
│   └── user_service.proto
├── lib/
│   ├── generated/    # Сгенерированный код
│   │   └── user_service.pb.dart
│   └── protobuf_extensions.dart  # Wrapper классы
└── scripts/
    └── generate.sh   # Скрипт генерации
```

### Рекомендации для .proto файлов

1. **Используйте семантические имена полей:**
```protobuf
message User {
  int32 id = 1;                    // ✅ Понятно
  string full_name = 2;            // ✅ Конкретно
  repeated string tags = 3;        // ✅ Описательно
}
```

2. **Группируйте связанные сообщения:**
```protobuf
// Запросы
message GetUserRequest { ... }
message CreateUserRequest { ... }
message UpdateUserRequest { ... }

// Ответы  
message UserResponse { ... }
message UsersListResponse { ... }
```

3. **Используйте enum для статусов:**
```protobuf
enum UserStatus {
  UNKNOWN = 0;      // Всегда начинайте с 0
  ACTIVE = 1;
  INACTIVE = 2;
  SUSPENDED = 3;
}
```

## Генерация Dart кода

### Автоматизация через скрипт

Создайте `scripts/generate.sh`:

```bash
#!/bin/bash
cd protos
protoc --dart_out=../lib/generated *.proto
echo "Protobuf код сгенерирован в lib/generated/"
```

### Настройка в IDE

**VS Code** - добавьте в `tasks.json`:
```json
{
  "version": "2.0.0",
  "tasks": [
    {
      "label": "Generate Protobuf",
      "type": "shell",
      "command": "protoc",
      "args": ["--dart_out=lib/generated", "protos/*.proto"],
      "group": "build",
      "presentation": {
        "echo": true,
        "reveal": "always"
      }
    }
  ]
}
```

## Создание wrapper классов

### Базовый паттерн wrapper'а

```dart
class RpcMessageWrapper implements IRpcSerializableMessage {
  final GeneratedMessage _proto;

  RpcMessageWrapper(this._proto);

  // Factory конструктор для создания
  factory RpcMessageWrapper.create({...}) {
    final proto = GeneratedMessage()
      ..field1 = value1
      ..field2 = value2;
    return RpcMessageWrapper(proto);
  }

  // Геттеры для доступа к полям
  Type get field1 => _proto.field1;
  Type get field2 => _proto.field2;

  // Обязательная сериализация для RPC
  @override
  Map<String, dynamic> toJson() {
    return {
      'field1': _proto.field1,
      'field2': _proto.field2,
    };
  }

  // Десериализация из JSON
  static RpcMessageWrapper fromJson(Map<String, dynamic> json) {
    final proto = GeneratedMessage()
      ..field1 = json['field1']
      ..field2 = json['field2'];
    return RpcMessageWrapper(proto);
  }

  // Доступ к protobuf объекту
  GeneratedMessage get proto => _proto;
}
```

### Обработка сложных типов

```dart
class RpcUser implements IRpcSerializableMessage {
  final User _proto;

  RpcUser(this._proto);

  factory RpcUser.create({
    required int id,
    required String name,
    required String email,
    List<String> tags = const [],
    UserStatus status = UserStatus.ACTIVE,
  }) {
    final proto = User()
      ..id = id
      ..name = name
      ..email = email
      ..tags.addAll(tags)
      ..status = status
      ..createdAt = Int64(DateTime.now().millisecondsSinceEpoch);
    return RpcUser(proto);
  }

  // Геттеры с безопасным доступом
  int get id => _proto.id;
  String get name => _proto.name;
  String get email => _proto.email;
  List<String> get tags => _proto.tags.toList();
  UserStatus get status => _proto.status;
  DateTime get createdAt => DateTime.fromMillisecondsSinceEpoch(_proto.createdAt.toInt());

  @override
  Map<String, dynamic> toJson() {
    return {
      'id': _proto.id,
      'name': _proto.name,
      'email': _proto.email,
      'tags': _proto.tags.toList(),
      'status': _proto.status.name,
      'created_at': _proto.createdAt.toInt(),
    };
  }

  static RpcUser fromJson(Map<String, dynamic> json) {
    final proto = User()
      ..id = json['id'] ?? 0
      ..name = json['name'] ?? ''
      ..email = json['email'] ?? ''
      ..tags.addAll(List<String>.from(json['tags'] ?? []))
      ..status = UserStatus.valueOf(json['status']) ?? UserStatus.UNKNOWN
      ..createdAt = Int64(json['created_at'] ?? 0);
    return RpcUser(proto);
  }

  User get proto => _proto;
}
```

## Реализация сервисов

### Серверная реализация

```dart
class ProtobufUserServiceServer extends ProtobufUserServiceContract {
  final Map<int, RpcUser> _users = {};

  @override
  Future<RpcGetUserResponse> getUser(RpcGetUserRequest request) async {
    final user = _users[request.userId];
    
    if (user == null) {
      return RpcGetUserResponse.error('Пользователь не найден');
    }

    return RpcGetUserResponse.success(user);
  }

  @override
  Future<RpcCreateUserResponse> createUser(RpcCreateUserRequest request) async {
    // Валидация
    if (request.name.trim().isEmpty) {
      return RpcCreateUserResponse.error('Имя не может быть пустым');
    }

    if (!request.email.contains('@')) {
      return RpcCreateUserResponse.error('Неверный email');
    }

    // Создание пользователя
    final user = RpcUser.create(
      id: DateTime.now().millisecondsSinceEpoch % 10000,
      name: request.name,
      email: request.email,
      tags: request.tags,
    );

    _users[user.id] = user;
    return RpcCreateUserResponse.success(user);
  }

  @override
  Future<RpcBatchCreateUsersResponse> batchCreateUsers(
    Stream<RpcCreateUserRequest> requests
  ) async {
    final createdUsers = <RpcUser>[];
    final errorMessages = <String>[];
    int totalErrors = 0;

    await for (final request in requests) {
      try {
        final response = await createUser(request);
        if (response.success && response.user != null) {
          createdUsers.add(response.user!);
        } else {
          errorMessages.add(response.errorMessage ?? 'Неизвестная ошибка');
          totalErrors++;
        }
      } catch (e) {
        errorMessages.add('Ошибка обработки: $e');
        totalErrors++;
      }
    }

    return RpcBatchCreateUsersResponse.create(
      users: createdUsers,
      totalCreated: createdUsers.length,
      totalErrors: totalErrors,
      errorMessages: errorMessages,
      success: totalErrors == 0,
    );
  }
}
```

### Клиентская реализация

```dart
class ProtobufUserServiceClient extends ProtobufUserServiceContract {
  final RpcEndpoint _endpoint;

  ProtobufUserServiceClient(this._endpoint);

  @override
  Future<RpcGetUserResponse> getUser(RpcGetUserRequest request) {
    return _endpoint
        .unaryRequest(serviceName: serviceName, methodName: 'getUser')
        .call(
          request: request,
          requestParser: RpcGetUserRequest.fromJson,
          responseParser: RpcGetUserResponse.fromJson,
        );
  }

  @override
  Future<RpcCreateUserResponse> createUser(RpcCreateUserRequest request) {
    return _endpoint
        .unaryRequest(serviceName: serviceName, methodName: 'createUser')
        .call(
          request: request,
          requestParser: RpcCreateUserRequest.fromJson,
          responseParser: RpcCreateUserResponse.fromJson,
        );
  }

  @override
  Future<RpcBatchCreateUsersResponse> batchCreateUsers(
    Stream<RpcCreateUserRequest> requests
  ) {
    return _endpoint
        .clientStream(serviceName: serviceName, methodName: 'batchCreateUsers')
        .call(
          requests: requests,
          requestParser: RpcCreateUserRequest.fromJson,
          responseParser: RpcBatchCreateUsersResponse.fromJson,
        );
  }
}
```

## Примеры RPC типов

### Унарный RPC

```dart
// Создание и вызов
final request = RpcGetUserRequest.create(userId: 123, includeTags: true);
final response = await client.getUser(request);

if (response.success && response.user != null) {
  print('Пользователь: ${response.user!.name}');
} else {
  print('Ошибка: ${response.errorMessage}');
}
```

### Серверный стрим

```dart
// Сервер отправляет множество ответов
final request = RpcListUsersRequest.create(limit: 10, offset: 0);
final stream = client.listUsers(request);

await for (final response in stream) {
  if (response.success) {
    for (final user in response.users) {
      print('Получен пользователь: ${user.name}');
    }
  }
}
```

### Клиентский стрим

```dart
// Клиент отправляет множество запросов
final userRequests = [
  RpcCreateUserRequest.create(name: 'Анна', email: 'anna@example.com'),
  RpcCreateUserRequest.create(name: 'Сергей', email: 'sergey@example.com'),
  RpcCreateUserRequest.create(name: 'Мария', email: 'maria@example.com'),
];

final requestStream = Stream.fromIterable(userRequests);
final response = await client.batchCreateUsers(requestStream);

print('Создано пользователей: ${response.totalCreated}');
print('Ошибок: ${response.totalErrors}');
```

### Двунаправленный стрим

```dart
// Настройка стрима событий
final requestController = StreamController<RpcWatchUsersRequest>();
final responseStream = client.watchUsers(requestController.stream);

// Подписка на события
responseStream.listen((response) {
  if (response.success) {
    print('Событие: ${response.event.eventType} для пользователя ${response.event.userId}');
  }
});

// Отправка запросов на отслеживание
requestController.add(RpcWatchUsersRequest.create(
  userIds: [1, 2, 3],
  eventTypes: ['USER_ACTIVITY', 'USER_UPDATE'],
));
```

## Best Practices

### 1. Именование и структура

```dart
// ✅ Хорошо: консистентное именование
class RpcCreateUserRequest implements IRpcSerializableMessage { ... }
class RpcCreateUserResponse implements IRpcSerializableMessage { ... }

// ❌ Плохо: непоследовательное именование  
class CreateUserReq implements IRpcSerializableMessage { ... }
class UserCreationResponse implements IRpcSerializableMessage { ... }
```

### 2. Валидация данных

```dart
class RpcCreateUserRequest implements IRpcSerializableMessage {
  // Встроенная валидация
  bool get isValid => name.trim().isNotEmpty && email.contains('@');
  
  String? validate() {
    if (name.trim().isEmpty) return 'Имя не может быть пустым';
    if (!email.contains('@')) return 'Неверный формат email';
    return null; // Валидация прошла
  }
}
```

### 3. Обработка ошибок

```dart
// Унифицированный формат ответов с ошибками
abstract class RpcResponseBase implements IRpcSerializableMessage {
  bool get success;
  String? get errorMessage;
  
  factory RpcResponseBase.error(String message) = RpcErrorResponse;
  factory RpcResponseBase.success() = RpcSuccessResponse;
}
```

### 4. Версионирование API

```protobuf
// Используйте отдельные пакеты для версий
package user_service.v1;
package user_service.v2;

// Или суффиксы в именах
message CreateUserV2Request { ... }
```

### 5. Производительность

```dart
// Переиспользуйте объекты там где возможно
class UserService {
  final _userCache = <int, RpcUser>{};
  
  RpcUser? getCachedUser(int id) => _userCache[id];
  void cacheUser(RpcUser user) => _userCache[user.id] = user;
}
```

### 6. Тестирование

```dart
void main() {
  group('ProtobufUserService', () {
    test('создание пользователя', () async {
      final request = RpcCreateUserRequest.create(
        name: 'Тест',
        email: 'test@example.com',
      );
      
      final response = await service.createUser(request);
      
      expect(response.success, isTrue);
      expect(response.user?.name, equals('Тест'));
    });
    
    test('валидация email', () {
      final request = RpcCreateUserRequest.create(
        name: 'Тест',
        email: 'invalid-email', // Невалидный email
      );
      
      expect(request.isValid, isFalse);
    });
  });
}
```

## Полный пример

См. файл `rpc_example/bin/protobuf_integration_example.dart` для полного рабочего примера со всеми типами RPC вызовов.

Для запуска примера:

```bash
cd rpc_example
dart run bin/protobuf_integration_example.dart
```

Этот пример демонстрирует:
- Унарные вызовы (getUser, createUser)
- Клиентский стрим (batchCreateUsers)  
- Серверный стрим (listUsers)
- Двунаправленный стрим (watchUsers)
- Обработку ошибок и валидацию
- Правильное управление ресурсами 