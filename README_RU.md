<div align="center">
  <img src="docs/icon/logo.svg" alt="RPC Dart Logo" width="80" height="80">
  <h1>RPC Dart</h1>
  <p><strong>RPC библиотека на чистом Dart для типобезопасного взаимодействия между компонентами</strong></p>
  
  <p>
    <a href="https://pub.dev/packages/rpc_dart"><img src="https://img.shields.io/pub/v/rpc_dart.svg" alt="Pub Version"></a>
    <a href="https://github.com/nogipx/rpc_dart/actions/workflows/ci.yml"><img src="https://github.com/nogipx/rpc_dart/workflows/CI/badge.svg" alt="CI"></a>
    <a href="https://coveralls.io/github/nogipx/rpc_dart?branch=main"><img src="https://coveralls.io/repos/github/nogipx/rpc_dart/badge.svg?branch=main" alt="Coverage Status"></a>
  </p>
  
  <p>
    <a href="README.md">🇺🇸 English</a> | 
    <a href="README_RU.md">🇷🇺 Русский</a>
  </p>
</div>

## Основные концепции

**RPC Dart** построен на следующих ключевых концепциях:

- **Контракты (Contracts)** — определяют API сервиса через интерфейсы и методы
- **Responder** — серверная часть, обрабатывает входящие запросы
- **Caller** — клиентская часть, отправляет запросы  
- **Endpoint** — точка подключения, управляет транспортом
- **Transport** — уровень передачи данных (InMemory, Isolate, HTTP)
- **Codec** — сериализация/десериализация сообщений

## Ключевые возможности

- **Полная поддержка RPC паттернов** — unary calls, server streams, client streams, bidirectional streams
- **Zero-Copy InMemory транспорт** — транспорт для передачи объектов без сериализации в одном процессе
- **Типобезопасность** — все запросы/ответы строго типизированы
- **Автоматическая трассировка** — trace ID генерируется автоматически, передается через RpcContext
- **Без внешних зависимостей** — только чистый Dart
- **Встроенные примитивы** — готовые обертки для String, Int, Double, Bool, List
- **Простое тестирование** — с InMemory транспортом и моками

## CORD

RPC Dart предлагает **CORD (Contract-Oriented Remote Domains)** — архитектурный подход для структурирования бизнес-логики через изолированные домены с типобезопасными RPC контрактами.

**📚 [Подробнее](docs/ru/cord.md)**

## Quick Start

**📚 [Полные примеры использования](example/)**

### 1. Определите контракт и модели

```dart
// Контракт с константами
abstract interface class ICalculatorContract {
  static const name = 'Calculator';
  static const methodCalculate = 'calculate';
}

// Zero-copy модели — обычные классы
class Request {
  final double a, b;
  final String op;
  Request(this.a, this.b, this.op);
}

class Response {
  final double result;
  Response(this.result);
}
```

### 2. Сервер (Responder)

```dart
final class CalculatorResponder extends RpcResponderContract {
  CalculatorResponder() : super(ICalculatorContract.name);

  @override
  void setup() {
    // Zero-copy метод — кодеки НЕ указываем
    addUnaryMethod<Request, Response>(
      methodName: ICalculatorContract.methodCalculate,
      handler: calculate,
    );
  }

  Future<Response> calculate(Request req, {RpcContext? context}) async {
    final result = switch (req.op) {
      'add' => req.a + req.b,
      _ => 0.0,
    };
    return Response(result);
  }
}
```

### 3. Клиент (Caller)

```dart
final class CalculatorCaller extends RpcCallerContract {
  CalculatorCaller(RpcCallerEndpoint endpoint) 
    : super(ICalculatorContract.name, endpoint);

  Future<Response> calculate(Request request) {
    return callUnary<Request, Response>(
      methodName: ICalculatorContract.methodCalculate,
      request: request,
    );
  }
}
```

### 4. Запуск

```dart
void main() async {
  // Создаем inmemory транспорт
  final (client, server) = RpcInMemoryTransport.pair();
  
  // Настраиваем endpoints
  final responder = RpcResponderEndpoint(transport: server);
  final caller = RpcCallerEndpoint(transport: client);
  
  // Регистрируем сервис
  responder.registerServiceContract(CalculatorResponder());
  responder.start();
  
  final calculator = CalculatorCaller(caller);
  
  // Вызываем RPC метод
  final result = await calculator.calculate(Request(10, 5, 'add'));
  print('10 + 5 = ${result.result}'); // 10 + 5 = 15.0
  
  // Закрываем
  await caller.close();
  await responder.close();
}
```

## Транспорты

### InMemory Transport (включен в основную библиотеку)
Идеально для разработки, тестирования и монолитных приложений:

```dart
final (clientTransport, serverTransport) = RpcInMemoryTransport.pair();
// Использование: разработка, unit-тесты, простые приложения
```

#### 🚀 Zero-Copy 

Для максимальной производительности RPC Dart поддерживает **zero-copy** передачу объектов без сериализации (только для `RpcInMemoryTransport`):

```dart
// Zero-copy контракт — просто не указывайте кодеки!
addUnaryMethod<UserRequest, UserResponse>(
  methodName: 'GetUser',
  handler: (request, {context}) async {
    return UserResponse(id: request.id, name: 'User ${request.id}');
  },
  // Кодеки НЕ указываем = автоматически zero-copy
);
```

### Режимы передачи данных

RPC Dart поддерживает три режима передачи данных в контрактах:

| Режим | Описание | Использование |
|-------|----------|---------------|
| **`zeroCopy`** | Принудительно zero-copy, кодеки игнорируются | Максимальная производительность |
| **`codec`** | Принудительная сериализация, кодеки обязательны | Универсальная совместимость |
| **`auto`** | **Умный выбор**: нет кодеков → zero-copy, есть кодеки → сериализация | Гибкая разработка |

**Режим `auto` (рекомендуется)** автоматически определяет оптимальный способ передачи:

```dart
final class SmartService extends RpcResponderContract {
  SmartService() : super('SmartService', 
    dataTransferMode: RpcDataTransferMode.auto); // ← Умный режим

  void setup() {
    // Автоматически выберет zero-copy (кодеки не указаны)
    addUnaryMethod<FastRequest, FastResponse>(
      'fastMethod', 
      handler: fastHandler,
    );
    
    // Автоматически выберет сериализацию (кодеки указаны)  
    addUnaryMethod<JsonRequest, JsonResponse>(
      'universalMethod',
      handler: universalHandler,
      requestCodec: jsonRequestCodec,   // ← Указаны кодеки
      responseCodec: jsonResponseCodec,
    );
  }
}
```

### Дополнительные транспорты

Вы можете использовать готовые транспорты из пакета **[rpc_dart_transports](https://pub.dev/packages/rpc_dart_transports)** или реализовать свои через интерфейс `IRpcTransport`.

**Доступные транспорты:**
- **Isolate Transport** — для CPU-интенсивных задач и изоляции сбоев
- **HTTP Transport** — для микросервисов и распределенных систем  
- **WebSocket Transport** — для real-time приложений

**Ключевое преимущество:** код домена остается неизменным при смене транспорта!

## Transport Router

**Transport Router** — умный прокси для маршрутизации RPC вызовов между транспортами по правилам с приоритетами.

### Основные возможности

- **Роутинг по сервисам** — направляет запросы к разным сервисам на разные транспорты
- **Условный роутинг** — сложная логика маршрутизации с доступом к контексту
- **Приоритеты правил** — точный контроль порядка проверки условий
- **Автоматический роутинг** — использует заголовки из `RpcCallerEndpoint`

### Пример использования

```dart
// Создаем транспорты для разных сервисов
final (userClient, userServer) = RpcInMemoryTransport.pair();
final (orderClient, orderServer) = RpcInMemoryTransport.pair();
final (paymentClient, paymentServer) = RpcInMemoryTransport.pair();

// Создаем роутер с правилами
final router = RpcTransportRouterBuilder()
  .routeCall(
    calledServiceName: 'UserService',
    toTransport: userClient,
    priority: 100,
  )
  .routeCall(
    calledServiceName: 'OrderService', 
    toTransport: orderClient,
    priority: 100,
  )
  .routeWhen(
    toTransport: paymentClient,
    whenCondition: (service, method, context) => 
      service == 'PaymentService' && 
      context?.getHeader('x-payment-method') == 'premium',
    priority: 150,
    description: 'Premium платежи на отдельный сервис',
  )
  .build();

// Используем роутер как обычный транспорт
final callerEndpoint = RpcCallerEndpoint(transport: router);
final userService = UserCaller(callerEndpoint);
final orderService = OrderCaller(callerEndpoint);

// Запросы автоматически направляются в нужные транспорты
final user = await userService.getUser(request);     // → userClient
final order = await orderService.createOrder(data); // → orderClient
```

**Применение:** Микросервисная архитектура, A/B тестирование, маршрутизация нагрузки, изоляция сервисов.

## Типы RPC взаимодействий

| Тип | Описание | Пример использования |
|-----|----------|---------------------|
| **Unary Call** | Запрос → Ответ | CRUD операции, валидация |
| **Server Stream** | Запрос → Поток ответов | Live обновления, прогресс |
| **Client Stream** | Поток запросов → Ответ | Batch upload, агрегация |
| **Bidirectional Stream** | Поток ↔ Поток | Чаты, real-time коллаборация |

## Встроенные примитивы

RPC Dart предоставляет готовые обертки для примитивных типов:

```dart
// Встроенные примитивы с кодеками
final name = RpcString('John');       // Строки
final age = RpcInt(25);              // Целые числа  
final height = RpcDouble(175.5);      // Дробные числа
final isActive = RpcBool(true);       // Булевы значения
final tags = RpcList<RpcString>([...]);  // Списки

// Удобные расширения
final message = 'Hello'.rpc;     // RpcString
final count = 42.rpc;            // RpcInt
final price = 19.99.rpc;         // RpcDouble
final enabled = true.rpc;        // RpcBool

// Числовые примитивы поддерживают арифметические операторы
final sum = RpcInt(10) + RpcInt(20);      // RpcInt(30)
final product = RpcDouble(3.14) * RpcDouble(2.0);  // RpcDouble(6.28)

// Доступ к значению через свойство .value
final greeting = RpcString('Hello ') + RpcString('World'); 
print(greeting.value); // "Hello World"
```

## StreamDistributor

**StreamDistributor** — это мощный менеджер для управления серверными стримами, который превращает обычный `StreamController` в брокер сообщений с расширенными возможностями:

### Основные возможности

- **Широковещательная публикация** — отправка сообщений всем подключенным клиентам
- **Фильтрованная публикация** — отправка по условию только определенным клиентам  
- **Управление жизненным циклом** — автоматическое создание/удаление стримов
- **Автоматическая очистка** — удаление неактивных стримов по таймеру
- **Метрики и мониторинг** — отслеживание активности и производительности

### Пример использования

```dart
// Создаем дистрибьютор для уведомлений
final distributor = StreamDistributor<NotificationEvent>(
  config: StreamDistributorConfig(
    enableAutoCleanup: true,
    inactivityThreshold: Duration(minutes: 5),
  ),
);

// Создаем клиентские стримы для разных пользователей
final userStream1 = distributor.createClientStreamWithId('user_123');
final userStream2 = distributor.createClientStreamWithId('user_456');

// Слушаем уведомления
userStream1.listen((notification) {
  print('User 123 получил: ${notification.message}');
});

// Отправляем всем клиентам
distributor.publish(NotificationEvent(
  message: 'Системное уведомление для всех',
  priority: Priority.normal,
));

// Отправляем только клиентам с определенными ID
distributor.publishFiltered(
  NotificationEvent(message: 'VIP уведомление'),
  (client) => ['user_123', 'premium_user_789'].contains(client.clientId),
);

// Получаем метрики
final metrics = distributor.metrics;
print('Активных клиентов: ${metrics.currentStreams}');
print('Отправлено сообщений: ${metrics.totalMessages}');
```

**Применение:** Идеально для реализации real-time уведомлений, чатов, live обновлений и других pub/sub сценариев в серверных стримах.

## Тестирование

```dart
// Unit тест с моком (используйте любую мок-библиотеку)
class MockUserService extends Mock implements UserCaller {}

test('should handle user not found', () async {
  final mockUserService = MockUserService();
  when(() => mockUserService.getUser(any()))
      .thenThrow(RpcException(code: RpcStatus.NOT_FOUND));
  
  final bloc = UserBloc(mockUserService);
  
  expect(
    () => bloc.add(LoadUserEvent(id: '123')),
    emitsError(isA<UserNotFoundException>()),
  );
});

// Integration тест с InMemory транспортом
test('full integration test', () async {
  final (clientTransport, serverTransport) = RpcInMemoryTransport.pair();
  
  final server = RpcResponderEndpoint(transport: serverTransport);
  server.registerServiceContract(UserResponder(MockUserRepository()));
  server.start();
  
  final client = UserCaller(RpcCallerEndpoint(transport: clientTransport));
  
  final response = await client.getUser(GetUserRequest(id: '123'));
  expect(response.user.id, equals('123'));
});
```

## FAQ

<details>
<summary><strong>Подходит ли для production?</strong></summary>

Рекомендуем тщательно протестировать библиотеку в вашей конкретной среде перед production деплоем.

</details>

<details>
<summary><strong>Как тестировать RPC код?</strong></summary>

```dart
// Unit тесты с моками
class MockUserService extends Mock implements UserCaller {}

test('должен обработать ошибку "пользователь не найден"', () async {
  final mockService = MockUserService();
  when(() => mockService.getUser(any()))
      .thenThrow(RpcException(code: RpcStatus.NOT_FOUND));
  
  final bloc = UserBloc(mockService);
  expect(() => bloc.loadUser('123'), throwsA(isA<UserNotFoundException>()));
});

// Integration тесты с InMemory транспортом
test('полный интеграционный тест', () async {
  final (client, server) = RpcInMemoryTransport.pair();
  final endpoint = RpcResponderEndpoint(transport: server);
  endpoint.registerServiceContract(TestService());
  endpoint.start();
  
  final caller = TestCaller(RpcCallerEndpoint(transport: client));
  final result = await caller.getData();
  expect(result.value, equals('expected'));
});
```

</details>

<details>
<summary><strong>Какую производительность ожидать?</strong></summary>

RPC Dart оптимизирован для реальных приложений. В типичных сценариях производительность более чем достаточная:

**Практические наблюдения:**
- InMemory транспорт имеет минимальные накладные расходы
- CBOR сериализация эффективнее JSON
- HTTP транспорт добавляет сетевую задержку
- Streaming эффективен для больших объемов данных

Для большинства приложений важнее удобство разработки и архитектурная чистота, чем микрооптимизации.

</details>

<details>
<summary><strong>Как обрабатывать ошибки?</strong></summary>

RPC Dart использует gRPC-статусы для унифицированной обработки ошибок:

```dart
try {
  final result = await userService.getUser(request);
} on RpcException catch (e) {
  showError('RPC ошибка: ${e.message}');
} on RpcDeadlineExceededException catch (e) {
  showError('Таймаут запроса: ${e.timeout}');
} on RpcCancelledException catch (e) {
  showError('Операция отменена: ${e.message}');
} catch (e) {
  // Обработка неожиданных ошибок
  logError('Unexpected error', error: e);
}
```

</details>

<details>
<summary><strong>Как масштабировать RPC архитектуру?</strong></summary>

**CORD принципы масштабирования:**

1. **Разделяйте домены** — каждый домен должен иметь четкую ответственность
2. **Используйте контракты** — для типобезопасного взаимодействия
3. **Минимизируйте связи** — домены общаются только через RPC
4. **Централизуйте логику** — бизнес-логика в Responder'ах
5. **Кэшируйте результаты** — в Caller'ах для UI оптимизации

```dart
// ❌ Плохо - прямые зависимости
class OrderBloc {
  final UserRepository userRepo;
  final PaymentRepository paymentRepo;
  final NotificationRepository notificationRepo;
}

// ✅ Хорошо - через RPC контракты
class OrderBloc {
  final UserCaller userService;
  final PaymentCaller paymentService;
  final NotificationCaller notificationService;
}
```

</details>

---

#### [Benchmark](https://bencher.dev/perf/rpc-dart?x_axis=version)

**Полезные ссылки:**
- [CORD Architecture](docs/ru/cord.md)
- [RPC Dart на pub.dev](https://pub.dev/packages/rpc_dart)
- [Исходный код на GitHub](https://github.com/nogipx/rpc_dart)
- [Примеры кода](example/)
- [Issues и поддержка](https://github.com/nogipx/rpc_dart/issues)

*Создавайте масштабируемые Flutter приложения с RPC Dart!*


