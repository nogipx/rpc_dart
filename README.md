[![Pub Version](https://img.shields.io/pub/v/rpc_dart.svg)](https://pub.dev/packages/rpc_dart)

# RPC Dart

> **RPC библиотека на чистом Dart для типобезопасного взаимодействия между компонентами**

RPC Dart — это RPC библиотека, построенная на чистом Dart, которая обеспечивает типобезопасное взаимодействие между компонентами через различные транспорты. В основной библиотеке включен InMemory транспорт, дополнительные транспорты (Isolate, HTTP) доступны в отдельной библиотеке `rpc_dart_transports`. Идеально подходит для организации больших Flutter приложений через архитектурный подход **CORD**.

## Основные концепции

**RPC Dart** построен на следующих ключевых концепциях:

- **Контракты (Contracts)** — определяют API сервиса через интерфейсы и методы
- **Responder** — серверная часть, обрабатывает входящие запросы
- **Caller** — клиентская часть, отправляет запросы  
- **Endpoint** — точка подключения, управляет транспортом
- **Transport** — уровень передачи данных (InMemory, Isolate, HTTP)
- **Codec** — сериализация/десериализация сообщений

## Ключевые возможности

- **🔄 Полная поддержка RPC паттернов** — unary calls, server streams, client streams, bidirectional streams
- **🚀 Встроенный InMemory транспорт** — для разработки и тестирования
- **🔒 Типобезопасность** — все запросы/ответы строго типизированы
- **⚡ Высокая производительность** — быстрая CBOR сериализация
- **🧪 Простое тестирование** — с InMemory транспортом и моками
- **📦 Нулевые внешние зависимости** — только чистый Dart
- **🎯 Встроенные примитивы** — готовые обертки для String, Int, Double, Bool, List

## CORD архитектура

RPC Dart поддерживает **CORD (Contract-Oriented Remote Domains)** — архитектурный подход для структурирования больших приложений через изолированные домены с типобезопасными RPC контрактами.

```dart
// Домены взаимодействуют через RPC контракты
class OrderBloc extends Bloc<OrderEvent, OrderState> {
  final OrderCaller _orderService; // RPC клиент домена
  
  Future<void> createOrder(CreateOrderEvent event) async {
    final response = await _orderService.createOrder(
      CreateOrderRequest(items: event.items),
    );
    emit(OrderCreated(response.order));
  }
}
```

**📚 Подробнее об архитектуре:** [CORD Architecture Guide](docs/cord_architecture_overview.md)

## Quick Start

### 1. Установка

```yaml
dependencies:
  rpc_dart: ^1.3.1
```

### 2. Определите контракт и модели

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

### 3. Создайте сервер (Responder)

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
  
  Future<CalculationResponse> calculate(CalculationRequest request) async {
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
  
  Stream<CalculationResponse> streamCalculate(Stream<CalculationRequest> requests) async* {
    await for (final request in requests) {
      yield await calculate(request);
    }
  }
}
```

### 4. Создайте клиент (Caller)

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

### 5. Запустите сервер и клиент

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
  
  // Делаем RPC вызовы
  final result = await calculator.add(10, 20);
  print('10 + 20 = $result'); // 10 + 20 = 30.0
  
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
Доступны в отдельной библиотеке `rpc_dart_transports`:

- **Isolate Transport** — для CPU-интенсивных задач и изоляции сбоев
- **HTTP Transport** — для микросервисов и распределенных систем

**Ключевое преимущество:** код домена остается неизменным при смене транспорта!

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

// Все примитивы поддерживают операторы
final sum = RpcInt(10) + RpcInt(20);  // RpcInt(30)
final text = RpcString('Hello ') + RpcString('World'); // Ошибка - используйте .value
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

## Производительность

**⚠️ Важно:** Производительность сильно зависит от среды выполнения, размера данных и паттернов использования. Рекомендуем запустить бенчмарки самостоятельно:

```bash
dart run benchmark/main.dart
```

Примерные результаты (могут сильно отличаться в вашей среде):

| Размер данных | Сериализация | Латентность RPC | Throughput |
|---------------|--------------|-----------------|-------------|
| 1KB | ~0.03мс | ~150мс | ~700 RPS |
| 10KB | ~0.05мс | ~150мс | ~580 RPS |
| 100KB | ~0.65мс | ~150мс | ~95 RPS |
| 1MB | ~4.3мс | ~590мс | ~6 RPS |

**Примечание:** Эти цифры получены в конкретной тестовой среде и могут не отражать реальную производительность вашего приложения.

## Использование без контрактов

RPC методы можно использовать напрямую через Endpoint без создания контрактов:

```dart
// Прямой вызов через endpoint
final response = await callerEndpoint.unaryRequest<AddRequest, AddResponse>(
  serviceName: 'Calculator',
  methodName: 'add',
  requestCodec: AddRequest.codec,
  responseCodec: AddResponse.codec,
  request: AddRequest(a: 5, b: 3),
);

// Создание стрима напрямую
final stream = callerEndpoint.serverStream<CountRequest, CountResponse>(
  serviceName: 'Calculator', 
  methodName: 'countTo',
  requestCodec: CountRequest.codec,
  responseCodec: CountResponse.codec,
  request: CountRequest(target: 10),
);
```

## Тестирование

RPC Dart упрощает тестирование:

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

## Интеграция с Flutter

RPC Dart отлично интегрируется с BLoC — популярным решением для Flutter state management:

```dart
class UserBloc extends Bloc<UserEvent, UserState> {
  final UserCaller _userService;
  
  UserBloc(this._userService) : super(UserInitial()) {
    on<LoadUserEvent>(_onLoadUser);
  }
  
  Future<void> _onLoadUser(LoadUserEvent event, Emitter emit) async {
    try {
      emit(UserLoading());
      final response = await _userService.getUser(GetUserRequest(id: event.id));
      emit(UserLoaded(response.user));
    } catch (e) {
      emit(UserError(e.toString()));
    }
  }
}
```

RPC Dart также совместим с другими популярными state management решениями — Provider, Riverpod, MobX и т.д.

## FAQ

<details>
<summary><strong>Чем отличается от обычных HTTP клиентов?</strong></summary>

RPC Dart обеспечивает:
- **Типобезопасность** на уровне компиляции — все ошибки выявляются до runtime
- **Множественные транспорты** без изменения кода — можно переключаться между InMemory, Isolate, HTTP
- **Streaming support** из коробки — server/client/bidirectional streams
- **Унифицированный API** для различных типов взаимодействий
- **Встроенную обработку ошибок** через gRPC-подобные статусы

</details>

<details>
<summary><strong>Подходит ли для production?</strong></summary>

RPC Dart предоставляет инструменты для production использования:
- **Строгая типизация** помогает избежать runtime ошибок
- **Обработка ошибок** через gRPC-статусы
- **Логирование и метрики** для мониторинга
- **Поддержка таймаутов** и graceful degradation

Однако рекомендуем тщательно протестировать библиотеку в вашей конкретной среде перед production деплоем.

</details>

<details>
<summary><strong>Как тестировать RPC код?</strong></summary>

RPC Dart упрощает тестирование:

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
- HTTP транспорт добавляет сетевую латентность
- Для больших данных рассмотрите streaming или chunking

**Важно:** Всегда измеряйте производительность в своей конкретной среде, так как результаты могут сильно отличаться.

</details>

<details>
<summary><strong>Когда использовать InMemory vs другие транспорты?</strong></summary>

**InMemory Transport:**
- ✅ Монолитные Flutter приложения
- ✅ Unit и integration тесты
- ✅ Быстрая разработка и прототипирование
- ❌ Изоляция CPU-интенсивных задач

**Isolate Transport (из rpc_dart_transports):**
- ✅ CPU-интенсивные вычисления без блокировки UI
- ✅ Изоляция критичного кода от сбоев
- ✅ Параллельная обработка данных

**HTTP Transport (из rpc_dart_transports):**
- ✅ Микросервисная архитектура
- ✅ Распределенные системы
- ✅ Взаимодействие с внешними сервисами

</details>

<details>
<summary><strong>Как обрабатывать ошибки?</strong></summary>

RPC Dart использует gRPC-статусы для унифицированной обработки ошибок:

```dart
try {
  final result = await userService.getUser(request);
} on RpcException catch (e) {
  switch (e.code) {
    case RpcStatus.NOT_FOUND:
      showError('Пользователь не найден');
    case RpcStatus.PERMISSION_DENIED:
      redirectToLogin();
    case RpcStatus.DEADLINE_EXCEEDED:
      showError('Таймаут запроса');
    default:
      showError('Неизвестная ошибка: ${e.message}');
  }
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

**Полезные ссылки:**
- [RPC Dart на pub.dev](https://pub.dev/packages/rpc_dart)
- [Исходный код на GitHub](https://github.com/nogipx/rpc_dart)
- [CORD Architecture Guide](docs/cord_architecture_overview.md)
- [Примеры кода](example/)
- [Issues и поддержка](https://github.com/nogipx/rpc_dart/issues)

*Создавайте масштабируемые Flutter приложения с RPC Dart!*
