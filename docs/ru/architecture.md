<!--
SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>

SPDX-License-Identifier: MIT
-->

# Архитектура

RPC Dart следует слоистой архитектуре, которая разделяет ответственности и обеспечивает гибкость в том, как компоненты взаимодействуют друг с другом. Понимание этой архитектуры поможет вам создавать лучшие приложения и принимать обоснованные решения о выборе транспорта и дизайне сервисов.

## Обзор архитектуры

Архитектура RPC Dart состоит из нескольких слоёв, каждый из которых имеет специфические обязанности:

- **Слой приложения** – Ваша бизнес-логика и реализации сервисов, которые используют RPC контракты.
  
- **RPC слой** – Контракты, вызывающие, отвечающие и логика маршрутизации.
  
- **Слой транспорта** – Сетевая коммуникация, сериализация и доставка сообщений.
  
- **Основной слой** – Базовые классы, утилиты и основы фреймворка.
  

## Слоистая архитектура

```
┌─────────────────────────────────────────┐
│           Слой приложения               │
│   ┌─────────────┐   ┌─────────────┐    │
│   │   Сервис    │   │  Клиентское │    │
│   │     A       │   │ приложение  │    │
│   └─────────────┘   └─────────────┘    │
└─────────────────────────────────────────┘
┌─────────────────────────────────────────┐
│             RPC слой                    │
│   ┌─────────────┐   ┌─────────────┐    │
│   │ Responder   │   │   Caller    │    │
│   │ Endpoint    │   │ Endpoint    │    │
│   └─────────────┘   └─────────────┘    │
│   ┌─────────────────────────────────┐   │
│   │         Контракты               │   │
│   └─────────────────────────────────┘   │
└─────────────────────────────────────────┘
┌─────────────────────────────────────────┐
│           Слой транспорта               │
│   ┌─────────┐ ┌─────────┐ ┌─────────┐  │
│   │InMemory │ │  HTTP   │ │WebSocket│  │
│   └─────────┘ └─────────┘ └─────────┘  │
└─────────────────────────────────────────┘
┌─────────────────────────────────────────┐
│           Основной слой                 │
│   ┌─────────────────────────────────┐   │
│   │   Базовые классы и утилиты      │   │
│   └─────────────────────────────────┘   │
└─────────────────────────────────────────┘
```

## Основные компоненты

### 1. Контракты

Контракты определяют интерфейс между сервисами. Они указывают:

- Имена сервисов и методов
- Типы запросов и ответов
- Поддерживаемые паттерны RPC (унарные, потоковые)

```dart
abstract interface class IUserServiceContract {
  static const name = 'UserService';
  static const methodGetUser = 'getUser';
  static const methodUpdateUser = 'updateUser';
  static const methodStreamNotifications = 'streamNotifications';
}
```

### 2. Эндпоинты

- **RpcResponderEndpoint** – Обрабатывает входящие RPC запросы:

```dart
final responder = RpcResponderEndpoint(transport: serverTransport);

// Регистрируем реализации сервисов
responder.registerServiceContract(UserServiceResponder());
responder.registerServiceContract(PaymentServiceResponder());

// Начинаем обработку запросов
responder.start();
```

- **RpcCallerEndpoint** – Инициирует RPC вызовы к удалённым сервисам:

```dart
final caller = RpcCallerEndpoint(transport: clientTransport);

// Создаём клиенты сервисов
final userService = UserServiceCaller(caller);
final paymentService = PaymentServiceCaller(caller);

// Делаем RPC вызовы
final user = await userService.getUser(userId);
```

### 3. Абстракция транспорта

Слой транспорта обрабатывает доставку сообщений между эндпоинтами:

```dart
abstract class IRpcTransport {
  bool get isClient;
  bool get supportsZeroCopy;
  int createStream();
  Future<void> sendMetadata(int streamId, RpcMetadata metadata, {bool endStream = false});
  Future<void> sendMessage(int streamId, Uint8List data, {bool endStream = false});
  Future<void> sendDirectObject(int streamId, Object object, {bool endStream = false});
  Stream<RpcTransportMessage> get incomingMessages;
  Future<void> finishSending(int streamId);
  Future<void> close();
  Future<RpcHealthStatus> health();
  Future<RpcHealthStatus> reconnect();
}
```

Такой контракт реализован в RPC Dart и позволяет заменять транспорты без
изменения бизнес-логики.

## Паттерны проектирования

### 1. Паттерн контракта

Сервисы определяются с использованием контрактов, которые задают интерфейс:

```dart
// Определение контракта
abstract interface class ICalculatorContract {
  static const name = 'Calculator';
  static const methodAdd = 'add';
  static const methodSubtract = 'subtract';
}

// Реализация responder'а
class CalculatorResponder extends RpcResponderContract {
  CalculatorResponder() : super(ICalculatorContract.name);
  
  @override
  void setup() {
addUnaryMethod<AddRequest, AddResponse>(
  methodName: ICalculatorContract.methodAdd,
  handler: _add,
);
  }
  
  Future<AddResponse> _add(AddRequest request, {RpcContext? context}) async {
return AddResponse(request.a + request.b);
  }
}

// Реализация caller'а
class CalculatorCaller extends RpcCallerContract {
  CalculatorCaller(RpcCallerEndpoint endpoint) 
: super(ICalculatorContract.name, endpoint);
  
  Future<AddResponse> add(AddRequest request) {
return callUnary<AddRequest, AddResponse>(
  methodName: ICalculatorContract.methodAdd,
  request: request,
);
  }
}
```

### 2. Паттерн маршрутизатора транспорта

Для сложных приложений вы можете маршрутизировать различные сервисы через разные транспорты:

```dart
final router = RpcTransportRouterBuilder.client()
.routeCall(calledServiceName: 'UserService', toTransport: httpTransport)
.routeCall(
  calledServiceName: 'NotificationService',
  toTransport: webSocketTransport,
)
.routeCall(
  calledServiceName: 'CacheService',
  toTransport: inMemoryTransport,
)
.build();

final caller = RpcCallerEndpoint(transport: router);
```

### 3. Паттерн middleware

Реализуйте сквозные задачи с помощью middleware:

```dart
class LoggingMiddleware implements IRpcMiddleware {
  @override
  Future<dynamic> processRequest(
String serviceName,
String methodName,
dynamic request,
  ) async {
log('Вызов $serviceName.$methodName');
return request;
  }

  @override
  Future<dynamic> processResponse(
String serviceName,
String methodName,
dynamic response,
  ) async {
log('Завершён $serviceName.$methodName');
return response;
  }
}

// Регистрируем middleware (для запуска хуков расширьте эндпоинты)
responder.addMiddleware(LoggingMiddleware());
```

> **Примечание.** Базовые эндпоинты хранят зарегистрированные middleware и
> отображают их количество в диагностике. Чтобы выполнять логику до/после
> обработчиков, расширьте эндпоинт и вызовите `processRequest`/`processResponse`
> вручную.

## Поток сообщений

### 1. Поток унарного вызова

```
Клиент                    Транспорт                   Сервер
  │                          │                          │
  │ 1. callUnary()           │                          │
  ├─────────────────────────▶│                          │
  │                          │ 2. RpcMessage            │
  │                          ├─────────────────────────▶│
  │                          │                          │ 3. processRequest()
  │                          │                          ├──────────────┐
  │                          │                          │              │
  │                          │                          │◀─────────────┘
  │                          │ 4. RpcMessage            │
  │                          │◀─────────────────────────┤
  │ 5. Response              │                          │
  │◀─────────────────────────┤                          │
```

### 2. Поток потоковой передачи

```
Клиент                    Транспорт                   Сервер
  │                          │                          │
  │ 1. callServerStream()    │                          │
  ├─────────────────────────▶│                          │
  │                          │ 2. RpcMessage            │
  │                          ├─────────────────────────▶│
  │                          │                          │ 3. processStreamRequest()
  │                          │                          ├──────────────┐
  │                          │ 4. Stream messages       │              │
  │                          │◀─────────────────────────┤              │
  │ 5. Stream<Response>      │                          │              │
  │◀─────────────────────────┤                          │              │
  │                          │                          │◀─────────────┘
```

## Архитектура обработки ошибок

RPC Dart реализует структурированную систему обработки ошибок:

### 1. Иерархия исключений

```dart
abstract class RpcException implements Exception {
  final String code;
  final String message;
  final Map<String, dynamic>? details;
}

class RpcTimeoutException extends RpcException {
  RpcTimeoutException(String message, Duration timeout);
}

class RpcCancelledException extends RpcException {
  RpcCancelledException(String message);
}

class RpcTransportException extends RpcException {
  RpcTransportException(String message, Exception cause);
}
```

### 2. Распространение ошибок

Ошибки автоматически сериализуются и распространяются через границы транспорта:

```dart
// Серверная сторона
Future<UserResponse> getUser(UserRequest request) async {
  if (request.userId.isEmpty) {
throw RpcException(
  code: 'INVALID_USER_ID',
  message: 'ID пользователя не может быть пустым',
  details: {'field': 'userId'},
);
  }
  // ... реализация
}

// Клиентская сторона
try {
  final user = await userService.getUser(UserRequest(userId: ''));
} on RpcException catch (e) {
  // Обрабатываем структурированные RPC ошибки
  print('Ошибка: ${e.code} - ${e.message}');
  if (e.details != null) {
print('Ошибка поля: ${e.details!['field']}');
  }
}
```

## Соображения производительности

### 1. Нулевое копирование с InMemory транспортом

Для одно-процессных приложений InMemory транспорт обеспечивает максимальную производительность:

```dart
class LargeDataService extends RpcResponderContract {
  @override
  void setup() {
addUnaryMethod<LargeData, ProcessedData>(
  methodName: 'processLargeData',
  handler: _processLargeData,
);
  }
  
  Future<ProcessedData> _processLargeData(LargeData data) async {
// Прямой доступ к объекту - без накладных расходов на сериализацию
return ProcessedData(data.processDirectly());
  }
}
```

### 2. Сериализация с сетевыми транспортами

Сетевые транспорты автоматически обрабатывают сериализацию:

```dart
// Для сетевых транспортов передавайте кодеки при регистрации методов
addUnaryMethod<MyRequest, MyResponse>(
  methodName: 'Process',
  handler: _process,
  requestCodec: RpcCodec(MyRequest.fromJson),
  responseCodec: RpcCodec(MyResponse.fromJson),
);
```

### 3. Управление соединением

`RpcHttp2CallerTransport` поддерживает одно мультиплексированное соединение и
экспонирует health/reconnect-хуки:

```dart
final httpTransport = await RpcHttp2CallerTransport.secureConnect(
  host: 'api.example.com',
);

final status = await httpTransport.health();
if (!status.isHealthy) {
  await httpTransport.reconnect();
}
```

## Паттерны масштабируемости

### 1. Декомпозиция сервисов

Разбивайте большие приложения на сфокусированные сервисы:

```dart
// Сервис управления пользователями
abstract interface class IUserServiceContract {
  static const name = 'UserService';
  // Операции CRUD пользователей
}

// Сервис обработки платежей
abstract interface class IPaymentServiceContract {
  static const name = 'PaymentService';
  // Операции платежей
}

// Сервис уведомлений
abstract interface class INotificationServiceContract {
  static const name = 'NotificationService';
  // Уведомления в реальном времени
}
```

### 2. Выбор транспорта по сервису

Используйте подходящие транспорты для разных типов сервисов (например
`httpTransport`, созданный через `RpcHttp2CallerTransport.secureConnect`, и
`webSocketTransport`, созданный через `RpcWebSocketCallerTransport.connect`):

```dart
// Сервисы реального времени используют WebSocket
final notificationService = NotificationServiceCaller(
  RpcCallerEndpoint(transport: webSocketTransport)
);

// CRUD сервисы используют HTTP
final userService = UserServiceCaller(
  RpcCallerEndpoint(transport: httpTransport)
);

// Внутренний кеш использует InMemory
final cacheService = CacheServiceCaller(
  RpcCallerEndpoint(transport: inMemoryTransport)
);
```

### 3. Балансировка нагрузки

Используйте несколько транспортов вместе с `RpcTransportRouter` или реализуйте
собственный транспорт через `IRpcTransport`, чтобы сделать round-robin/health-check
стратегию. Можно распределять вызовы между несколькими `RpcHttp2CallerTransport`
или маршрутизировать по метаданным, таким как тариф или география.

## Архитектура тестирования

Архитектура RPC Dart делает тестирование простым:

### 1. Мок сервисы

```dart
class MockUserService extends RpcResponderContract {
  MockUserService() : super(IUserServiceContract.name);
  
  @override
  void setup() {
addUnaryMethod<GetUserRequest, UserResponse>(
  methodName: IUserServiceContract.methodGetUser,
  handler: _getMockUser,
);
  }
  
  Future<UserResponse> _getMockUser(GetUserRequest request) async {
return UserResponse(
  user: User(id: request.userId, name: 'Тестовый пользователь'),
);
  }
}
```

### 2. Интеграционное тестирование

```dart
void main() {
  group('Интеграция UserService', () {
late RpcResponderEndpoint responder;
late RpcCallerEndpoint caller;

setUp(() async {
  final (clientTransport, serverTransport) = RpcInMemoryTransport.pair();
  
  responder = RpcResponderEndpoint(transport: serverTransport);
  responder.registerServiceContract(MockUserService());
  responder.start();
  
  caller = RpcCallerEndpoint(transport: clientTransport);
});

tearDown(() async {
  await caller.close();
  await responder.close();
});

test('должен успешно получить пользователя', () async {
  final userService = UserServiceCaller(caller);
  final response = await userService.getUser(GetUserRequest(userId: '123'));
  
  expect(response.user.id, equals('123'));
  expect(response.user.name, equals('Тестовый пользователь'));
});
  });
}
```

## Лучшие практики

### 1. Дизайн сервисов

- **Единственная ответственность**: Каждый сервис должен иметь одну чёткую цель
- **Разделение интерфейсов**: Держите контракты сфокусированными и минимальными
- **Инверсия зависимостей**: Зависьте от контрактов, а не от реализаций

### 2. Обработка ошибок

- **Структурированные ошибки**: Используйте RpcException с кодами и деталями
- **Изящная деградация**: Обрабатывайте ошибки на соответствующих уровнях
- **Прерыватель цепи**: Реализуйте таймауты и повторы

### 3. Производительность

- **Выбор транспорта**: Выбирайте правильный транспорт для каждого случая использования
- **Потоковая передача**: Используйте потоки для больших наборов данных и обновлений в реальном времени
- **Кеширование**: Реализуйте кеширование там, где это уместно

### 4. Тестирование

- **Модульные тесты**: Тестируйте контракты и реализации отдельно
- **Интеграционные тесты**: Тестируйте с реальными транспортами
- **Мок сервисы**: Используйте InMemory транспорт для быстрых, изолированных тестов

Архитектура RPC Dart обеспечивает гибкость, производительность и поддерживаемость, сохраняя управляемую сложность. Понимая эти паттерны и принципы, вы можете создавать надёжные, масштабируемые приложения, которые легко тестировать и поддерживать.
