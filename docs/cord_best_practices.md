# CORD Best Practices

> **Практические рекомендации для эффективного использования Contract-Oriented Remote Domains**

> 📖 **См. также:** [CORD General Practices](cord_general_practices.md) - применение классических практик программирования в контексте CORD архитектуры

## Содержание

- [Проектирование доменов](#проектирование-доменов)
- [Классификация доменов](#классификация-доменов)
- [Дизайн контрактов](#дизайн-контрактов)
- [Реализация Responder'ов](#реализация-responderов)
- [Работа с Caller'ами](#работа-с-callerами)
- [UI слой и управление состоянием](#ui-слой-и-управление-состоянием)
- [Тестирование](#тестирование)
- [Анти-паттерны](#анти-паттерны)

## Проектирование доменов

### Принцип единственной ответственности для доменов

**Рекомендуемый подход:** Каждый домен должен отвечать за одну четко определенную бизнес-область.

```dart
// Рекомендуется: четкая доменная граница
abstract interface class IUserContract implements IRpcContract {
  Future<GetProfileResponse> getProfile(GetProfileRequest request);
  Future<UpdateProfileResponse> updateProfile(UpdateProfileRequest request);
  Future<ValidateCredentialsResponse> validateCredentials(ValidateCredentialsRequest request);
}

abstract interface class INotificationContract implements IRpcContract {
  Future<SendEmailResponse> sendEmail(SendEmailRequest request);
  Future<SendPushResponse> sendPush(SendPushRequest request);
  Stream<NotificationEvent> subscribeToEvents(SubscribeRequest request);
}
```

**Неправильный подход:** Смешанные ответственности
```dart
// Не рекомендуется: нарушение принципа единственной ответственности
abstract interface class IUserNotificationContract implements IRpcContract {
  Future<GetProfileResponse> getProfile(GetProfileRequest request);
  Future<SendEmailResponse> sendEmail(SendEmailRequest request);
  Future<ValidatePaymentResponse> validatePayment(ValidatePaymentRequest request);
}
```

## Классификация доменов

В CORD архитектуре домены классифицируются на две основные категории: **бизнес-домены** и **инфраструктурные домены**.

### Бизнес-домены

**Назначение:** Содержат предметную логику, которая непосредственно связана с бизнес-требованиями и правилами предметной области.

**Характеристики:**
- Представляют конкретные бизнес-области (пользователи, заказы, платежи)
- Содержат доменную логику и бизнес-правила
- Могут взаимодействовать с другими бизнес-доменами через RPC
- Используют инфраструктурные домены для технических операций

```dart
// Пример бизнес-домена
abstract interface class IOrderContract implements IRpcContract {
  Future<CreateOrderResponse> createOrder(CreateOrderRequest request);
  Future<CancelOrderResponse> cancelOrder(CancelOrderRequest request);
  Future<GetOrderStatusResponse> getOrderStatus(GetOrderStatusRequest request);
}

final class OrderResponder extends RpcResponderContract implements IOrderContract {
  final PaymentCaller _payments;           // Другой бизнес-домен
  final InventoryCaller _inventory;        // Другой бизнес-домен
  final LocalNotificationCaller _notifications; // Инфраструктурный домен
  final LoggingCaller _logging;            // Инфраструктурный домен
  
  OrderResponder({
    required PaymentCaller payments,
    required InventoryCaller inventory,
    required LocalNotificationCaller notifications,
    required LoggingCaller logging,
  }) : _payments = payments,
       _inventory = inventory,
       _notifications = notifications,
       _logging = logging,
       super('OrderService');
  
  @override
  Future<CreateOrderResponse> createOrder(CreateOrderRequest request) async {
    // Бизнес-логика
    final availability = await _inventory.checkAvailability(
      CheckAvailabilityRequest(productIds: request.items.map((e) => e.id).toList()),
    );
    
    final payment = await _payments.processPayment(
      ProcessPaymentRequest(amount: request.total, method: request.paymentMethod),
    );
    
    final order = Order.create(request, payment);
    
    // Использование инфраструктурных доменов
    await _notifications.showNotification(ShowNotificationRequest(
      title: 'Заказ создан',
      message: 'Заказ #${order.id} успешно создан',
      type: NotificationType.success,
    ));
    
    await _logging.logEvent(LogEventRequest(
      level: LogLevel.info,
      message: 'Order created: ${order.id}',
      context: {'userId': request.userId, 'amount': request.total},
    ));
    
    return CreateOrderResponse(order: order);
  }
}
```

### Инфраструктурные домены

**Назначение:** Предоставляют техническую функциональность, которая переиспользуется различными бизнес-доменами.

**Характеристики:**
- Инкапсулируют технические аспекты (уведомления, кеширование, логирование)
- Не содержат бизнес-логику
- Предоставляют стабильные API для технических операций
- Могут иметь platform-specific реализации

```dart
// Примеры инфраструктурных доменов

// Локальные уведомления
abstract interface class ILocalNotificationContract implements IRpcContract {
  Future<ShowNotificationResponse> showNotification(ShowNotificationRequest request);
  Future<ScheduleNotificationResponse> scheduleNotification(ScheduleNotificationRequest request);
  Future<CancelNotificationResponse> cancelNotification(CancelNotificationRequest request);
  Stream<NotificationInteractionEvent> subscribeToInteractions();
}

// Кеширование
abstract interface class ICacheContract implements IRpcContract {
  Future<SetCacheResponse> set(SetCacheRequest request);
  Future<GetCacheResponse> get(GetCacheRequest request);
  Future<DeleteCacheResponse> delete(DeleteCacheRequest request);
  Future<ClearCacheResponse> clear(ClearCacheRequest request);
}

// Навигация
abstract interface class INavigationContract implements IRpcContract {
  Future<NavigateToResponse> navigateTo(NavigateToRequest request);
  Future<GoBackResponse> goBack(GoBackRequest request);
  Future<ReplaceRouteResponse> replaceRoute(ReplaceRouteRequest request);
  Stream<NavigationEvent> subscribeToNavigation();
}

// Логирование
abstract interface class ILoggingContract implements IRpcContract {
  Future<LogEventResponse> logEvent(LogEventRequest request);
  Future<LogErrorResponse> logError(LogErrorRequest request);
  Future<SetLogLevelResponse> setLogLevel(SetLogLevelRequest request);
}
```

### Взаимодействие между типами доменов

**Правила взаимодействия:**
1. **Бизнес-домены → Бизнес-домены:** Через RPC для координации бизнес-процессов
2. **Бизнес-домены → Инфраструктурные домены:** Через RPC для технических операций
3. **Инфраструктурные домены → Бизнес-домены:** Не рекомендуется (инверсия зависимостей)
4. **Инфраструктурные домены → Инфраструктурные домены:** Редко, только для композиции

```dart
final class AnalyticsResponder extends RpcResponderContract implements IAnalyticsContract {
  final CacheCaller _cache;           // Инфраструктурный домен
  final LoggingCaller _logging;       // Инфраструктурный домен
  final StorageCaller _storage;       // Инфраструктурный домен
  
  AnalyticsResponder({
    required CacheCaller cache,
    required LoggingCaller logging,
    required StorageCaller storage,
  }) : _cache = cache,
       _logging = logging,
       _storage = storage,
       super('AnalyticsService');
  
  @override
  Future<TrackEventResponse> trackEvent(TrackEventRequest request) async {
    // Проверяем кеш
    final cached = await _cache.get(CacheKeyRequest(key: 'user_${request.userId}'));
    
    // Сохраняем событие
    await _storage.saveEvent(SaveEventRequest(
      event: AnalyticsEvent.fromRequest(request),
      timestamp: DateTime.now(),
    ));
    
    // Логируем
    await _logging.logEvent(LogEventRequest(
      level: LogLevel.debug,
      message: 'Analytics event tracked: ${request.eventName}',
    ));
    
    return TrackEventResponse(success: true);
  }
}
```

### Рекомендации по организации доменов

**Паттерн Dependency Injection:**
```dart
// Для InMemory транспорта - одна пара на приложение  
final (callerTransport, responderTransport) = RpcInMemoryTransport.pair();
final callerEndpoint = RpcCallerEndpoint(transport: callerTransport);
final responderEndpoint = RpcResponderEndpoint(transport: responderTransport);

// Все Caller'ы используют один общий endpoint для междоменной коммуникации
final orderResponder = OrderResponder(
  payments: PaymentCaller(callerEndpoint),           // Общий endpoint
  inventory: InventoryCaller(callerEndpoint),        // Общий endpoint  
  notifications: LocalNotificationCaller(callerEndpoint), // Общий endpoint
  logging: LoggingCaller(callerEndpoint),            // Общий endpoint
);

// Все Responder'ы регистрируются на одном endpoint'е
responderEndpoint.registerContract(PaymentResponder(repository: paymentRepo));
responderEndpoint.registerContract(InventoryResponder(repository: inventoryRepo));
responderEndpoint.registerContract(NotificationResponder());
responderEndpoint.registerContract(LoggingResponder());
responderEndpoint.registerContract(orderResponder);
```

### Минимизация связей между доменами

**Принцип:** Домен должен зависеть только от тех доменов, которые непосредственно необходимы для выполнения его бизнес-логики.

```dart
// Рекомендуется: разделение бизнес и инфраструктурных зависимостей
final class OrderResponder extends RpcResponderContract implements IOrderContract {
  // Бизнес-домены: только критически необходимые
  final PaymentCaller _payments;    // Необходим для обработки платежей
  final InventoryCaller _inventory; // Необходим для проверки наличия товаров
  
  // Инфраструктурные домены: технические операции
  final LocalNotificationCaller _notifications; // Уведомления пользователю
  final LoggingCaller _logging;     // Логирование событий
  final CacheCaller _cache;         // Кеширование данных
}

// Не рекомендуется: избыточные бизнес-зависимости
final class OrderResponder extends RpcResponderContract implements IOrderContract {
  final PaymentCaller _payments;
  final InventoryCaller _inventory;
  final UserCaller _users;          // Данные пользователя должны приходить в request
  final EmailCaller _email;         // Лучше через событийный механизм или NotificationDomain
  final SmsCaller _sms;             // Лучше через событийный механизм или NotificationDomain
  final AnalyticsCaller _analytics; // Лучше через событийный механизм
}
```

## Дизайн контрактов

### Стратегии версионирования контрактов

```dart
abstract interface class IOrderContract implements IRpcContract {
  // Версия 1 - оригинальный метод
  Future<CreateOrderResponse> createOrder(CreateOrderRequest request);
  
  // Версия 2 - расширенный метод (обратно совместимый)
  Future<CreateOrderResponseV2> createOrderV2(CreateOrderRequestV2 request);
  
  // Важно: не изменяйте существующие методы
  // Не удаляйте старые методы до завершения миграции всех клиентов
}
```

## Реализация Responder'ов

### Применение Event Sourcing для аудита

```dart
final class OrderResponder extends RpcResponderContract implements IOrderContract {
  final OrderRepository _repository;
  final EventCaller _events;
  
  OrderResponder({
    required OrderRepository repository,
    required EventCaller events,
  }) : _repository = repository,
       _events = events,
       super('OrderService');
  
  @override
  void setup() {
    addUnaryMethod<CreateOrderRequest, CreateOrderResponse>(
      methodName: 'createOrder',
      handler: createOrder,
      requestCodec: CreateOrderRequest.codec,
      responseCodec: CreateOrderResponse.codec,
    );
  }
  
  @override
  Future<CreateOrderResponse> createOrder(CreateOrderRequest request) async {
    final order = Order.create(
      userId: request.userId,
      items: request.items,
      createdAt: DateTime.now(),
    );
    
    await _repository.save(order);
    
    // Публикация события для аудита и реактивности
    await _events.publishEvent(PublishEventRequest(
      event: OrderCreatedEvent(
        orderId: order.id,
        userId: order.userId,
        totalAmount: order.totalAmount,
        timestamp: DateTime.now(),
      ),
    ));
    
    return CreateOrderResponse(order: order);
  }
}
```

## Работа с Caller'ами

### Dependency Injection для Caller'ов

Поскольку Caller'ы stateless, их можно создавать где угодно. Важно: все Caller'ы должны использовать **один общий endpoint** для междоменной коммуникации. Правильный подход - прокидывать зависимости через конструктор.

```dart
// Правильно: Dependency Injection через конструктор
final class OrderResponder extends RpcResponderContract implements IOrderContract {
  final PaymentCaller _payments;
  final InventoryCaller _inventory;
  final NotificationCaller _notifications;
  
  OrderResponder({
    required PaymentCaller payments,
    required InventoryCaller inventory,
    required NotificationCaller notifications,
  }) : _payments = payments,
       _inventory = inventory,
       _notifications = notifications,
       super('OrderService');
  
  @override
  void setup() {
    addUnaryMethod<CreateOrderRequest, CreateOrderResponse>(
      methodName: 'createOrder',
      handler: createOrder,
      requestCodec: CreateOrderRequest.codec,
      responseCodec: CreateOrderResponse.codec,
    );
  }
}

// Создание и инъекция зависимостей
final (callerTransport, responderTransport) = RpcInMemoryTransport.pair();
final callerEndpoint = RpcCallerEndpoint(transport: callerTransport);

final orderResponder = OrderResponder(
  payments: PaymentCaller(callerEndpoint),           // Общий endpoint для всех
  inventory: InventoryCaller(callerEndpoint),        // Stateless - без проблем
  notifications: NotificationCaller(callerEndpoint),
);

final subscriptionResponder = SubscriptionResponder(
  payments: PaymentCaller(callerEndpoint),           // Тот же endpoint
  users: UserCaller(callerEndpoint),                 // Междоменная коммуникация работает
);
```

**Неправильно:** Создание зависимостей внутри класса
```dart
// Анти-паттерн: жесткие зависимости
final class OrderResponder extends RpcResponderContract implements IOrderContract {
  final PaymentCaller _payments = PaymentCaller(someEndpoint);       // Жестко зашито!
  final InventoryCaller _inventory = InventoryCaller(someEndpoint);  // Не тестируемо!
  
  // Нельзя подставить моки, сложно тестировать, нарушает DIP
}
```

## UI слой и управление состоянием

### Координация междоменных операций в UI

```dart
// BLoC координирует междоменные операции
class CheckoutBloc extends Bloc<CheckoutEvent, CheckoutState> {
  final CartCaller _cart;
  final OrderCaller _orders;
  final PaymentCaller _payments;
  
  Future<void> _handleCheckout(CheckoutRequested event, Emitter<CheckoutState> emit) async {
    emit(CheckoutInProgress());
    
    try {
      // Координация последовательности вызовов
      final cart = await _cart.getCurrentCart(GetCartRequest(userId: event.userId));
      
      // Проверка корректности данных
      if (cart.items.isEmpty) {
        emit(CheckoutFailed('Cart is empty'));
        return;
      }
      
      // Создание заказа
      final order = await _orders.createOrder(CreateOrderRequest(
        userId: event.userId,
        items: cart.items,
        deliveryAddress: event.deliveryAddress,
      ));
      
      // Очистка корзины только после успешного создания заказа
      await _cart.clearCart(ClearCartRequest(userId: event.userId));
      
      emit(CheckoutSuccess(order: order.order));
      
    } catch (e) {
      emit(CheckoutFailed('Checkout failed: $e'));
    }
  }
}
```

**Важное замечание:** BLoC не должен содержать бизнес-логику доменов. Его задача — координация UI взаимодействий и вызовов доменных операций через Caller'ы.

### Реактивные обновления через Stream

```dart
class NotificationBloc extends Bloc<NotificationEvent, NotificationState> {
  final NotificationCaller _notifications;
  StreamSubscription? _notificationSubscription;
  
  NotificationBloc({required NotificationCaller notifications}) 
      : _notifications = notifications {
    on<StartListening>(_onStartListening);
    on<NotificationReceived>(_onNotificationReceived);
  }
  
  Future<void> _onStartListening(StartListening event, Emitter<NotificationState> emit) async {
    // Подписка на поток уведомлений
    _notificationSubscription = _notifications
        .subscribeToNotifications(SubscribeRequest(userId: event.userId))
        .listen((notification) {
      add(NotificationReceived(notification));
    });
  }
  
  @override
  Future<void> close() {
    _notificationSubscription?.cancel();
    return super.close();
  }
}
```

## Тестирование

### Модульное тестирование доменов

```dart
// Правильный подход: мокируем внешние зависимости (Caller'ы)
void main() {
  group('OrderResponder', () {
    late OrderResponder orderResponder;
    late MockPaymentCaller mockPayments;
    late MockInventoryCaller mockInventory;
    
    setUp(() {
      mockPayments = MockPaymentCaller();
      mockInventory = MockInventoryCaller();
      
      orderResponder = OrderResponder(
        payments: mockPayments,
        inventory: mockInventory,
        notifications: MockNotificationCaller(),
        logging: MockLoggingCaller(),
      );
    });
    
    test('should create order successfully when payment succeeds', () async {
      // Arrange
      when(() => mockInventory.checkAvailability(any()))
          .thenAnswer((_) async => CheckAvailabilityResponse(allAvailable: true));
      
      when(() => mockPayments.processPayment(any()))
          .thenAnswer((_) async => ProcessPaymentResponse(isSuccessful: true));
      
      // Act
      final response = await orderResponder.createOrder(CreateOrderRequest(
        userId: 'user_123',
        items: [OrderItem(productId: 'product_1', quantity: 2)],
      ));
      
      // Assert
      expect(response.order.status, equals(OrderStatus.confirmed));
      verify(() => mockPayments.processPayment(any())).called(1);
    });
  });
}
```

**Важно:** Не мокируйте объект, который вы тестируете. Responder — это объект тестирования, а Caller'ы — его зависимости.

### Тестирование междоменных взаимодействий

```dart
// Тестирование сложных сценариев с несколькими доменами
test('should coordinate order creation across multiple domains', () async {
  // Arrange: настройка моков для всех задействованных доменов
  when(() => mockInventory.checkAvailability(any()))
      .thenAnswer((_) async => CheckAvailabilityResponse(allAvailable: true));
  
  when(() => mockPayments.processPayment(any()))
      .thenAnswer((_) async => ProcessPaymentResponse(isSuccessful: true, transactionId: 'txn_123'));
  
  when(() => mockNotifications.sendOrderConfirmation(any()))
      .thenAnswer((_) async => SendOrderConfirmationResponse(delivered: true));
  
  // Act
  final response = await orderResponder.createOrder(
    CreateOrderRequest(
      userId: 'user_123',
      items: ['product_1', 'product_2'],
      total: 100.0,
    ),
  );
  
  // Assert: проверяем последовательность вызовов
  verifyInOrder([
    () => mockInventory.checkAvailability(any()),
    () => mockPayments.processPayment(any()),
    () => mockNotifications.sendOrderConfirmation(any()),
  ]);
  
  expect(response.order.status, equals(OrderStatus.confirmed));
});
```

## Анти-паттерны

### Избегайте циклических зависимостей между доменами

```dart
// Неправильно: домены зависят друг от друга
final class UserResponder extends RpcResponderContract implements IUserContract {
  final OrderCaller _orders; // User зависит от Order
}

final class OrderResponder extends RpcResponderContract implements IOrderContract {
  final UserCaller _users;   // Order зависит от User - циклическая зависимость!
}

// Правильно: введение промежуточного домена или Event-based коммуникации
final class UserResponder extends RpcResponderContract implements IUserContract {
  final EventCaller _events; // Только события
}

final class OrderResponder extends RpcResponderContract implements IOrderContract {
  final EventCaller _events; // Коммуникация через события
}
```

### Избегайте статичной связи доменов

```dart
// Неправильно: жесткая связь через статические ссылки
final class OrderResponder extends RpcResponderContract implements IOrderContract {
  @override
  Future<CreateOrderResponse> createOrder(CreateOrderRequest request) async {
    // Прямое обращение к другому домену - нарушение изоляции
    final user = await UserResponder.staticInstance.getProfile(request.userId);
    return CreateOrderResponse(order: Order.create(user, request.items));
  }
}

// Правильно: зависимости через Caller'ы
final class OrderResponder extends RpcResponderContract implements IOrderContract {
  final UserCaller _users; // Dependency injection через Caller
  
  OrderResponder({required UserCaller users}) : _users = users;
  
  @override
  Future<CreateOrderResponse> createOrder(CreateOrderRequest request) async {
    final user = await _users.getProfile(GetProfileRequest(userId: request.userId));
    return CreateOrderResponse(order: Order.create(user.profile, request.items));
  }
}
```

## Заключение

Эффективное применение CORD архитектуры с rpc_dart основывается на следующих ключевых принципах:

1. **Четкое разделение ответственности** — каждый домен имеет единственную бизнес-область
2. **Формальные контракты** — домены взаимодействуют только через типизированные RPC вызовы
3. **Транспортная независимость** — один код работает с InMemory, Isolate, HTTP транспортами
4. **Dependency Injection** — Caller'ы прокидываются через конструктор для тестируемости
5. **Общий endpoint** — все Caller'ы используют один endpoint для междоменной коммуникации

CORD представляет собой мощный архитектурный подход для сложных приложений с множественными доменами. Для простых CRUD приложений традиционные паттерны могут оказаться более подходящими.

*Архитектурные решения должны соответствовать сложности и требованиям конкретного проекта* 