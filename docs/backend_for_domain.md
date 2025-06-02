# Backend-for-Domain (BFD): Архитектурный манифест

> **"Каждый домен — это отдельный бэкенд с формальным API"**

**Backend-for-Domain (BFD)** — это архитектурная философия для структурирования сложных приложений через изоляцию доменов с формальными контрактами взаимодействия. BFD решает фундаментальную проблему роста сложности в больших системах: когда код разных бизнес-областей смешивается, система становится непредсказуемой и хрупкой.

## Мотивация: Архитектурные границы в больших системах

В сложных приложениях с множественными бизнес-областями критически важно обеспечить **четкую изоляцию доменов**. Когда логика пользователей, заказов, платежей и уведомлений смешивается в одних классах, система становится непредсказуемой и хрупкой.

**Ключевая проблема:** традиционные подходы решают техническую структуру кода (слои, зависимости), но не обеспечивают **доменную изоляцию** на архитектурном уровне.

## Решение: Backend-for-Domain

### Основная идея

> **Каждый домен приложения структурируется как отдельный бэкенд-сервис с публичным API, независимо от того, где он физически выполняется**

BFD меняет мышление: вместо "классов и методов" мыслим "сервисами и контрактами".

### Ключевые принципы

#### 1. **Домен = Автономный сервис**
```dart
// Каждый домен — изолированная единица с четким API
abstract interface class IUserContract implements IRpcContract {
  Future<GetProfileResponse> getProfile(GetProfileRequest request);
  Future<UpdateProfileResponse> updateProfile(UpdateProfileRequest request);
  // Только операции, относящиеся к пользователям
}

abstract interface class IOrderContract implements IRpcContract {
  Future<CreateOrderResponse> createOrder(CreateOrderRequest request);
  Future<CancelOrderResponse> cancelOrder(CancelOrderRequest request);
  // Только операции, относящиеся к заказам
}
```

#### 2. **Формальные контракты взаимодействия**
Домены общаются **только** через `RpcCallerContract`, как настоящие микросервисы:

```dart
// OrderResponder получает Caller'ы других доменов
final class OrderResponder extends RpcResponderContract implements IOrderContract {
  final PaymentCaller _payments;      // Caller для Payment домена
  final InventoryCaller _inventory;   // Caller для Inventory домена  
  final NotificationCaller _notifications; // Caller для Notification домена
  
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
  
  @override
  Future<CreateOrderResponse> createOrder(CreateOrderRequest request) async {
    // 1. Проверяем товар через RPC вызов
    final availability = await _inventory.checkAvailability(
      CheckAvailabilityRequest(productIds: request.items),
    );
    
    // 2. Обрабатываем платеж через RPC вызов  
    final payment = await _payments.processPayment(
      ProcessPaymentRequest(amount: request.total),
    );
    
    // 3. Уведомляем через RPC вызов
    await _notifications.sendOrderConfirmation(
      OrderConfirmationRequest(orderId: order.id, userId: request.userId),
    );
    
    return CreateOrderResponse(order: order);
  }
}
```

#### 3. **Транспортная независимость**
Один и тот же код работает локально и распределенно:

```dart
// Локально (в памяти) 
final (clientTransport, serverTransport) = RpcInMemoryTransport.pair();
final clientEndpoint = RpcCallerEndpoint(transport: clientTransport);

final orderResponder = OrderResponder(
  payments: PaymentCaller(clientEndpoint),      // Вызов через InMemory
  inventory: InventoryCaller(clientEndpoint),   // Вызов через InMemory  
  notifications: NotificationCaller(clientEndpoint), // Вызов через InMemory
);

// Через сеть (микросервисы) - только транспорт меняется!
final httpEndpoint = RpcCallerEndpoint(transport: RpcHttpTransport('api.example.com'));

final orderResponder = OrderResponder(
  payments: PaymentCaller(httpEndpoint),        // Вызов через HTTP
  inventory: InventoryCaller(httpEndpoint),     // Вызов через HTTP
  notifications: NotificationCaller(httpEndpoint), // Вызов через HTTP  
);

// Код домена остается неизменным!
```

#### 4. **Гибкость транспорта под задачу**
Один домен может работать через разные транспорты в зависимости от ситуации:

```
Разработка → Тестирование → Production → Isolate → Микросервис
    ↓            ↓            ↓         ↓          ↓
 InMemory    InMemory     InMemory   Process    HTTP/gRPC
```

**Выбор транспорта зависит от задачи:**
- `InMemory` — быстрая разработка, тесты, простые проекты
- `Isolate` — CPU-интенсивные задачи, изоляция сбоев  
- `HTTP/gRPC` — интеграция с внешними системами, распределенные команды
- **Код доменов остается неизменным!**

## Архитектурные паттерны BFD

### Паттерн 1: Изолированные домены (Responder)
```dart
// Responder содержит только бизнес-логику домена
final class UserResponder extends RpcResponderContract implements IUserContract {
  final UserRepository _repository;  // Только локальные зависимости
  
  UserResponder(this._repository) : super('UserService');
  
  @override
  void setup() {
    addUnaryMethod<GetProfileRequest, GetProfileResponse>(
      methodName: 'getProfile',
      handler: getProfile,
      requestCodec: GetProfileRequest.codec,
      responseCodec: GetProfileResponse.codec,
    );
  }
  
  @override
  Future<GetProfileResponse> getProfile(GetProfileRequest request) async {
    // Только чистая бизнес-логика домена
    final user = await _repository.findById(request.userId);
    final preferences = calculatePreferences(user);
    
    return GetProfileResponse(
      profile: UserProfile(
        id: user.id,
        name: user.name,
        email: user.email,
        preferences: preferences,
      ),
    );
  }
}
```

### Паттерн 2: Междоменное взаимодействие через Caller
```dart
// Responder получает Caller'ы других доменов в конструкторе
final class RecommendationResponder extends RpcResponderContract implements IRecommendationContract {
  final UserCaller _users;         // Caller для User домена
  final OrderCaller _orders;       // Caller для Order домена
  final InventoryCaller _inventory; // Caller для Inventory домена
  
  RecommendationResponder({
    required UserCaller users,
    required OrderCaller orders,
    required InventoryCaller inventory,
  }) : _users = users,
       _orders = orders,
       _inventory = inventory,
       super('RecommendationService');
  
  @override
  void setup() {
    addUnaryMethod<GetRecommendationsRequest, GetRecommendationsResponse>(
      methodName: 'getRecommendations',
      handler: getRecommendations,
      requestCodec: GetRecommendationsRequest.codec,
      responseCodec: GetRecommendationsResponse.codec,
    );
  }
  
  @override
  Future<GetRecommendationsResponse> getRecommendations(GetRecommendationsRequest request) async {
    // Собираем данные из разных доменов через RPC вызовы
    final profileResponse = await _users.getProfile(GetProfileRequest(userId: request.userId));
    final ordersResponse = await _orders.getUserOrders(GetUserOrdersRequest(userId: request.userId)); 
    final catalogResponse = await _inventory.getAvailableProducts(GetProductsRequest());
    
    // Применяем доменную логику рекомендаций
    final recommendations = calculateRecommendations(
      profileResponse.profile, 
      ordersResponse.orders, 
      catalogResponse.products,
    );
    
    return GetRecommendationsResponse(products: recommendations);
  }
}
```

### Паттерн 3: UI координация через Caller
```dart
// UI работает с доменами только через Caller'ы
class CheckoutBloc extends Bloc<CheckoutEvent, CheckoutState> {
  final CartCaller _cart;    // Caller для Cart домена
  final OrderCaller _orders; // Caller для Order домена
  
  CheckoutBloc({
    required CartCaller cart,
    required OrderCaller orders,
  }) : _cart = cart,
       _orders = orders;
  
  Future<void> _checkout(CheckoutEvent event, Emitter emit) async {
    try {
      // UI координирует междоменные RPC вызовы
      final cartResponse = await _cart.getCurrentCart(GetCartRequest(userId: event.userId));
      final orderResponse = await _orders.createOrder(CreateOrderRequest(items: cartResponse.cart.items));
      await _cart.clearCart(ClearCartRequest(userId: event.userId));
      
      emit(CheckoutCompleted(orderResponse.order));
    } catch (e) {
      emit(CheckoutFailed(e.toString()));
    }
  }
}
```

## Преимущества BFD

### 1. **Предсказуемость**
- Каждый вызов имеет четкий контракт входа/выхода
- Побочные эффекты контролируются через явные вызовы
- Легко понять, что делает код

### 2. **Тестируемость**
```dart
// Тестируем домен в полной изоляции с моками Caller'ов
void main() {
  test('Order creation with payment failure', () async {
    final mockPayments = MockPaymentCaller(shouldFail: true);  
    final mockInventory = MockInventoryCaller(hasStock: true);
    final mockNotifications = MockNotificationCaller();
    
    final orderResponder = OrderResponder(
      payments: mockPayments,
      inventory: mockInventory, 
      notifications: mockNotifications,
    );
    
    expect(
      () => orderResponder.createOrder(CreateOrderRequest(...)),
      throwsA(isA<PaymentFailedException>()),
    );
  });
}
```

### 3. **Масштабируемость команд**
- Каждая команда владеет своими доменами
- Изменения в одном домене не влияют на другие
- Четкие границы ответственности

## Сравнение с другими подходами

### vs Clean Architecture
| Clean Architecture | Backend-for-Domain |
|-------------------|-------------------|
| Слоевая структура (Entities → Use Cases → Interface Adapters → Frameworks) | Доменная структура (Contract → Responder → Caller) |
| Зависимости направлены к ядру | Зависимости через формальные RPC контракты |
| Абстракции для внешних систем (Repository, Gateway) | Абстракции для всех доменных взаимодействий |
| Архитектура в рамках одного процесса | Архитектура с возможностью распределения |

### vs Domain-Driven Design  
| DDD | BFD |
|-----|-----|
| Bounded Contexts как концептуальные границы | Домены как технические сервисы с API |
| Ubiquitous Language | Типизированные RPC контракты |
| Агрегаты и Value Objects | Request/Response объекты |
| Domain Events | RPC вызовы между доменами |
| Anti-Corruption Layer | Caller как адаптер к другим доменам |

### vs Microservices
| Микросервисы | BFD |
|-------------|-----|
| Каждый сервис — отдельный процесс | Домен может работать в процессе или удаленно |
| Сетевое взаимодействие по умолчанию | Транспорт настраивается (InMemory/HTTP/gRPC) |
| Операционная сложность с первого дня | Простота разработки, сложность по мере роста |
| Данные изолированы по сервисам | Гибкость в стратегии персистенции |

## Когда использовать BFD

### Подходит для:
- **Больших приложений** (15+ экранов, 5+ разработчиков)
- **Сложной доменной логики** с множественными взаимодействиями

### Возможно не подходит для:
- **Простых CRUD приложений**
- **Небольших команд**
- **Проектов** с высокими требованиями к производительности

## Практические сценарии применения

### Сценарий 1: Разработка и тестирование
```dart
// Все домены в памяти — быстро и просто
final (clientTransport, serverTransport) = RpcInMemoryTransport.pair();
final endpoint = RpcCallerEndpoint(transport: clientTransport);

final userCaller = UserCaller(endpoint);
final orderCaller = OrderCaller(endpoint);
```

### Сценарий 2: CPU-интенсивные задачи
```dart
// Выносим тяжелый домен в Isolate
final isolateEndpoint = RpcCallerEndpoint(transport: RpcIsolateTransport());
final analyticsCaller = AnalyticsCaller(isolateEndpoint);  // В отдельном процессе

final orderResponder = OrderResponder(
  analytics: analyticsCaller,  // Тяжелые вычисления в Isolate
  payments: PaymentCaller(localEndpoint),  // Остальное локально
);
```

### Сценарий 3: Интеграция с внешними системами
```dart
// Часть доменов — внешние сервисы
final httpEndpoint = RpcCallerEndpoint(transport: RpcHttpTransport('api.payment.com'));
final paymentCaller = PaymentCaller(httpEndpoint);  // Внешний платежный сервис
// Важно чтобы внешний сервис использовал тот же контракт что и caller

final orderResponder = OrderResponder(
  payments: paymentCaller,     // Внешний HTTP сервис
  inventory: InventoryCaller(localEndpoint), // Локальная логика
);
```

## Заключение

**Backend-for-Domain** — это не просто паттерн, а **архитектурная философия**, которая меняет способ мышления о структуре приложений. 

Вместо технической декомпозиции (UI → Business Logic → Data) BFD предлагает **доменную декомпозицию** (User Domain ↔ Order Domain ↔ Payment Domain), где каждый домен — это полноценный бэкенд с формальным API.

Такой подход обеспечивает:
- **Предсказуемость** — четкие контракты и отсутствие скрытых зависимостей
- **Гибкость** — один код работает локально, в Isolate, по HTTP
- **Модульность** — домены можно независимо тестировать и разрабатывать
- **Интегративность** — легкая работа с внешними системами

BFD особенно эффективен для **проектов со сложными междоменными взаимодействиями**, где важна архитектурная гибкость. Он позволяет принимать решения о деплое на уровне конфигурации, а не кода.

---

**Ключевой инсайт:** BFD обеспечивает четкие архитектурные границы между доменами, делая их формальными и неизбежными. Это создает основу для предсказуемого развития системы.

*"Архитектура — это то, что остается неизменным при изменении требований. BFD делает границы доменов такой архитектурной константой."*
