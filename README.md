[![Pub Version](https://img.shields.io/pub/v/rpc_dart.svg)](https://pub.dev/packages/rpc_dart)
[![CI](https://github.com/nogipx/rpc_dart/workflows/CI/badge.svg)](https://github.com/nogipx/rpc_dart/actions/workflows/ci.yml)
[![Coverage Status](https://coveralls.io/repos/github/nogipx/rpc_dart/badge.svg?branch=main)](https://coveralls.io/github/nogipx/rpc_dart?branch=main)

# RPC Dart

> **RPC библиотека на чистом Dart для типобезопасного взаимодействия между компонентами**

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
- **Встроенный InMemory транспорт** — для разработки и тестирования
- **Типобезопасность** — все запросы/ответы строго типизированы
- **Автоматическая трассировка** — trace ID генерируется автоматически, передается через RpcContext
- **Без внешних зависимостей** — только чистый Dart
- **Встроенные примитивы** — готовые обертки для String, Int, Double, Bool, List
- **Простое тестирование** — с InMemory транспортом и моками

## CORD

RPC Dart предлагает **CORD (Contract-Oriented Remote Domains)** — архитектурный подход для структурирования бизнес-логики через изолированные домены с типобезопасными RPC контрактами.

**📚 [Подробнее](docs/cord.md)**

## Quick Start

### [Готовые примеры использования](example/)

### 1. Определите контракт и модели

```dart
// Request/Response объекты реализуют IRpcSerializable
class CalculationRequest implements IRpcSerializable {
  final double a, b;
  final String operation; // 'add', 'subtract', 'multiply', 'divide'
  
  CalculationRequest({required this.a, required this.b, required this.operation});
  
  @override
  Map<String, dynamic> toJson() => {'a': a, 'b': b, 'operation': operation};
  
  static CalculationRequest fromJson(Map<String, dynamic> json) => CalculationRequest(
    a: json['a'] is int ? (json['a'] as int).toDouble() : json['a'],
    b: json['b'] is int ? (json['b'] as int).toDouble() : json['b'],
    operation: json['operation'],
  );
  
  static RpcCodec<CalculationRequest> get codec => RpcCodec(CalculationRequest.fromJson);
}

class CalculationResponse implements IRpcSerializable {
  final double? result;
  final bool success;
  final String? errorMessage;
  
  CalculationResponse({this.result, this.success = true, this.errorMessage});
  
  @override
  Map<String, dynamic> toJson() => {
    'result': result, 'success': success, 'errorMessage': errorMessage,
  };
  
  static CalculationResponse fromJson(Map<String, dynamic> json) => CalculationResponse(
    result: json['result'], success: json['success'] ?? true, errorMessage: json['errorMessage'],
  );
      
  static RpcCodec<CalculationResponse> get codec => RpcCodec(CalculationResponse.fromJson);
}
```

### 2. Создайте сервер (Responder)

```dart
class CalculatorResponder extends RpcResponderContract {
  CalculatorResponder() : super('CalculatorService');
  
  @override
  void setup() {
    addUnaryMethod<CalculationRequest, CalculationResponse>(
      methodName: 'calculate',
      handler: calculate,
      requestCodec: CalculationRequest.codec,
      responseCodec: CalculationResponse.codec,
    );
    
    addBidirectionalMethod<CalculationRequest, CalculationResponse>(
      methodName: 'streamCalculate',
      handler: streamCalculate,
      requestCodec: CalculationRequest.codec,
      responseCodec: CalculationResponse.codec,
    );
  }
  
  Future<CalculationResponse> calculate(CalculationRequest request, {RpcContext? context}) async {
    try {
      double result;
      switch (request.operation) {
        case 'add': result = request.a + request.b; break;
        case 'subtract': result = request.a - request.b; break;
        case 'multiply': result = request.a * request.b; break;
        case 'divide':
          if (request.b == 0) throw Exception('Division by zero');
          result = request.a / request.b; break;
        default: throw Exception('Unknown operation: ${request.operation}');
      }
      return CalculationResponse(result: result);
    } catch (e) {
      return CalculationResponse(success: false, errorMessage: e.toString());
    }
  }
  
  Stream<CalculationResponse> streamCalculate(Stream<CalculationRequest> requests, {RpcContext? context}) async* {
    await for (final request in requests) {
      yield await calculate(request, context: context);
    }
  }
}
```

### 3. Создайте клиент (Caller)

```dart
class CalculatorCaller extends RpcCallerContract {
  CalculatorCaller(RpcCallerEndpoint endpoint) : super('CalculatorService', endpoint);
  
  Future<CalculationResponse> calculate(CalculationRequest request) {
    return endpoint.unaryRequest<CalculationRequest, CalculationResponse>(
      serviceName: serviceName,
      methodName: 'calculate',
      requestCodec: CalculationRequest.codec,
      responseCodec: CalculationResponse.codec,
      request: request,
    );
  }
  
  Stream<CalculationResponse> streamCalculate(Stream<CalculationRequest> requests) {
    return endpoint.bidirectionalStream<CalculationRequest, CalculationResponse>(
      serviceName: serviceName,
      methodName: 'streamCalculate',
      requestCodec: CalculationRequest.codec,
      responseCodec: CalculationResponse.codec,
      requests: requests,
    );
  }
  
  // Удобный метод для сложения
  Future<double> add(double a, double b) async {
    final response = await calculate(CalculationRequest(a: a, b: b, operation: 'add'));
    if (!response.success) throw Exception(response.errorMessage);
    return response.result!;
  }
}
```

### 4. Запустите сервер и клиент

```dart
void main() async {
  // Создаем InMemory транспорт
  final (clientTransport, serverTransport) = RpcInMemoryTransport.pair();
  
  // Настраиваем сервер
  final serverEndpoint = RpcResponderEndpoint(transport: serverTransport);
  serverEndpoint.registerServiceContract(CalculatorResponder());
  serverEndpoint.start(); // Важно: явно запускаем эндпоинт!
  
  // Настраиваем клиент
  final clientEndpoint = RpcCallerEndpoint(transport: clientTransport);
  final calculator = CalculatorCaller(clientEndpoint);
  
  // Делаем RPC вызовы с автоматической генерацией trace ID
  final result = await calculator.add(10, 20);
  print('10 + 20 = $result'); // 10 + 20 = 30.0
  
  // Или с пользовательским контекстом
  final context = RpcContextUtils.withTracing(traceId: 'user_operation_123');
  final resultWithContext = await calculator.calculate(
    CalculationRequest(a: 5, b: 3, operation: 'multiply'),
    context: context,
  );
  
  // Работаем со стримом вычислений
  final requests = Stream.fromIterable([
    CalculationRequest(a: 5, b: 3, operation: 'add'),
    CalculationRequest(a: 10, b: 2, operation: 'multiply'),
    CalculationRequest(a: 15, b: 3, operation: 'divide'),
  ]);
  
  await for (final response in calculator.streamCalculate(requests)) {
    if (response.success) {
      print('Result: ${response.result}');
    } else {
      print('Error: ${response.errorMessage}');
    }
  }
  
  // Закрываем ресурсы
  await serverEndpoint.close();
  await clientEndpoint.close();
}
```

## Транспорты

### InMemory Transport (включен в основную библиотеку)
Идеально для разработки, тестирования и монолитных приложений:

```dart
final (clientTransport, serverTransport) = RpcInMemoryTransport.pair();
// Использование: разработка, unit-тесты, простые приложения
```

### Дополнительные транспорты

RPC Dart поддерживает создание кастомных транспортов через интерфейс `RpcTransport`:

```dart
// Пример кастомного транспорта
class CustomHttpTransport implements RpcTransport {
  @override
  Future<void> send(RpcMessage message) async {
    // Реализация отправки через HTTP
  }
  
  @override
  Stream<RpcMessage> get messageStream => _messageController.stream;
}

final endpoint = RpcCallerEndpoint(transport: CustomHttpTransport());
```

**Возможные варианты расширения:**
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

Производительность зависит от многих факторов: среды выполнения, размера данных, типа транспорта. Для получения точных цифр запустите бенчмарки в вашей среде:

```bash
dart run benchmark/main.dart
```

**Общие наблюдения:**
- InMemory транспорт имеет минимальные накладные расходы
- CBOR сериализация обычно быстрее JSON
- HTTP транспорт добавляет сетевую задержку
- Для больших данных рассмотрите streaming или chunking

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

<details>
<summary><strong>Benchmark</strong></summary>
<a href="https://bencher.dev/perf/rpc-dart?lower_value=false&upper_value=false&lower_boundary=false&upper_boundary=false&x_axis=version&branches=336e550c-b07f-4a22-9a82-8ec26eb358de&testbeds=c793799b-60f0-408a-832f-0afad9807be8&benchmarks=e99c2168-aa9a-410f-b5d3-53be26e8aba2%2Ca139d61d-6327-4c37-9309-acb50a135912%2C46ba5e12-ef65-4255-bdc5-4fff6b1ac8c4%2Ccb8a8f66-581b-445a-8c3b-dbe7d0d70847&measures=cac9b185-2af3-4ffe-a992-d3e3139d3e95&start_time=1744741020215&end_time=1749579420215&tab=plots&plots_search=a271874c-7479-4152-b94e-54db025f6abf&key=true&reports_per_page=4&branches_per_page=8&testbeds_per_page=8&benchmarks_per_page=8&plots_per_page=8&reports_page=1&branches_page=1&testbeds_page=1&benchmarks_page=1&plots_page=1&utm_medium=share&utm_source=bencher&utm_content=img&utm_campaign=perf%2Bimg&utm_term=rpc-dart"><img src="https://api.bencher.dev/v0/projects/rpc-dart/perf/img?branches=336e550c-b07f-4a22-9a82-8ec26eb358de&heads=&testbeds=c793799b-60f0-408a-832f-0afad9807be8&benchmarks=e99c2168-aa9a-410f-b5d3-53be26e8aba2%2Ca139d61d-6327-4c37-9309-acb50a135912%2C46ba5e12-ef65-4255-bdc5-4fff6b1ac8c4%2Ccb8a8f66-581b-445a-8c3b-dbe7d0d70847&measures=cac9b185-2af3-4ffe-a992-d3e3139d3e95&start_time=1744741020215&end_time=1749579420215&title=rpc_dart_throughput" title="rpc_dart_throughput" alt="rpc_dart_throughput for rpc_dart - Bencher" /></a>
</details>

**Полезные ссылки:**
- [CORD Architecture](docs/contract_oriented_remote_domains.md)
- [RPC Dart на pub.dev](https://pub.dev/packages/rpc_dart)
- [Исходный код на GitHub](https://github.com/nogipx/rpc_dart)
- [Примеры кода](example/)
- [Issues и поддержка](https://github.com/nogipx/rpc_dart/issues)

*Создавайте масштабируемые Flutter приложения с RPC Dart!*


