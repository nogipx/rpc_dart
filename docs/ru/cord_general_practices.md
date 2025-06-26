# CORD General Practices

> **Практики программирования в контексте Contract-Oriented Remote Domains**

Как применять общепринятые практики программирования при работе с CORD архитектурой.

> 📚 **См. также:** [CORD Architecture Overview](cord_architecture_overview.md) и [CORD Best Practices](cord_best_practices.md)

## Содержание

- [Принципы дизайна данных](#принципы-дизайна-данных)
  - [Именование Request/Response объектов](#именование-requestresponse-объектов)
  - [Композиция vs наследование в Request/Response](#композиция-vs-наследование-в-requestresponse)
  - [Иммутабельность в междоменных вызовах](#иммутабельность-в-междоменных-вызовах)
- [Валидация и обработка ошибок](#валидация-и-обработка-ошибок)
- [Паттерны производительности](#паттерны-производительности)
- [Паттерны тестирования](#паттерны-тестирования)
- [Общие анти-паттерны в CORD контексте](#общие-анти-паттерны-в-cord-контексте)

## Принципы дизайна данных

### Именование Request/Response объектов

В CORD контрактах особенно важно четкое именование, так как эти объекты служат API между доменами.

```dart
// Рекомендуется: описательные имена отражают доменную операцию
class CreateOrderRequest extends IRpcSerializable {
  final String userId;
  final List<OrderItem> items;
  final String? couponCode;
  final DeliveryAddress deliveryAddress;
  final PaymentMethod paymentMethod;
}

class CreateOrderResponse extends IRpcSerializable {
  final Order order;
  final PaymentResult paymentResult;
  final EstimatedDelivery estimatedDelivery;
}

// Не рекомендуется: слишком общие имена затрудняют понимание контракта
class Request extends IRpcSerializable {
  final Map<String, dynamic> data;
}

class Response extends IRpcSerializable {
  final bool success;
  final String? message;
}
```

### Композиция vs наследование в Request/Response

В CORD особенно важно избегать наследования в DTO, так как изменения базовых классов могут нарушить совместимость контрактов.

```dart
// Рекомендуется: композиция обеспечивает стабильность контрактов
class CreateOrderRequest extends IRpcSerializable {
  final UserInfo userInfo;         // Композиция - изменения UserInfo не влияют на контракт
  final List<OrderItem> items;
  final DeliveryOptions delivery;  // Композиция - можно эволюционировать независимо
  final PaymentInfo payment;       // Композиция - изолированные изменения
}

// Не рекомендуется: наследование создает хрупкие контракты
class CreateOrderRequest extends BaseUserRequest {
  final List<OrderItem> items;
  // Изменения в BaseUserRequest могут сломать существующие Caller'ы
}
```

### Иммутабельность в междоменных вызовах

```dart
// Неправильно: передача мутабельных объектов через RPC
class CreateOrderRequest extends IRpcSerializable {
  final User user;          // Мутабельный объект - может измениться во время обработки
  final List<CartItem> items; // Мутабельный список - нарушение контракта
}

// Правильно: передача иммутабельных данных
class CreateOrderRequest extends IRpcSerializable {
  final String userId;      // Примитив - гарантированно иммутабельный
  final List<String> productIds; // Список примитивов - безопасно
  final double totalAmount; // Примитив - не может быть изменен
  final String deliveryAddress; // Примитив или Value Object
}
```

## Валидация и обработка ошибок

### Валидация входных данных в Responder'ах

В CORD валидация особенно критична, так как данные приходят через RPC и могут быть некорректными.

```dart
@override
Future<CreateOrderResponse> createOrder(CreateOrderRequest request) async {
  // Ранняя валидация предотвращает передачу некорректных данных дальше по цепочке
  if (request.items.isEmpty) {
    throw RpcException('Order items cannot be empty');
  }
  
  if (request.userId.isEmpty) {
    throw RpcException('User ID is required');
  }
  
  for (final item in request.items) {
    if (item.quantity <= 0) {
      throw RpcException('Item quantity must be positive: ${item.productId}');
    }
  }
  
  // После валидации можно безопасно работать с данными
  final availability = await _inventory.checkAvailability(
    CheckAvailabilityRequest(productIds: request.items.map((e) => e.productId).toList()),
  );
  
  // ... остальная бизнес-логика
}
```

### Многоуровневая обработка ошибок RPC

В CORD важно различать типы ошибок: технические (RPC), доменные и бизнес-логические.

```dart
@override
Future<CreateOrderResponse> createOrder(CreateOrderRequest request) async {
  try {
    final payment = await _payments.processPayment(
      ProcessPaymentRequest(
        amount: request.totalAmount,
        paymentMethod: request.paymentMethod,
      ),
    );
    
    if (!payment.isSuccessful) {
      // Бизнес-логическая ошибка: платеж отклонен
      throw OrderCreationException('Payment failed: ${payment.errorMessage}');
    }
    
  } on RpcException catch (e) {
    // Техническая ошибка: проблемы с соединением или сериализацией
    throw OrderCreationException('Payment service unavailable: $e');
  } on PaymentException catch (e) {
    // Доменная ошибка: нарушение бизнес-правил платежного домена
    throw OrderCreationException('Payment validation failed: $e');
  }
  
  // ... продолжение бизнес-логики
}
```

## Паттерны производительности

### Кэширование в Caller'ах

Caller'ы подходят для кэширования, так как они инкапсулируют логику доступа к удаленным доменам.

```dart
class UserCaller {
  final RpcCallerEndpoint _endpoint;
  final Map<String, UserProfile> _profileCache = {};
  
  UserCaller(this._endpoint);
  
  Future<GetProfileResponse> getProfile(GetProfileRequest request) async {
    // Проверяем кэш перед RPC вызовом
    if (_profileCache.containsKey(request.userId)) {
      return GetProfileResponse(profile: _profileCache[request.userId]!);
    }
    
    final response = await _endpoint.unaryRequest<GetProfileRequest, GetProfileResponse>(
      serviceName: 'UserService',
      methodName: 'getProfile',
      requestCodec: GetProfileRequest.codec,
      responseCodec: GetProfileResponse.codec,
      request: request,
    );
    
    _profileCache[request.userId] = response.profile;
    return response;
  }
  
  // Инвалидация кэша при изменениях - важно для корректности данных
  Future<UpdateProfileResponse> updateProfile(UpdateProfileRequest request) async {
    final response = await _endpoint.unaryRequest<UpdateProfileRequest, UpdateProfileResponse>(
      serviceName: 'UserService',
      methodName: 'updateProfile',
      requestCodec: UpdateProfileRequest.codec,
      responseCodec: UpdateProfileResponse.codec,
      request: request,
    );
    
    // Удаляем устаревшие данные из кэша
    _profileCache.remove(request.userId);
    
    return response;
  }
}
```

### Управление таймаутами RPC операций

В CORD особенно важно управлять таймаутами, так как операции могут блокировать UI или другие домены.

```dart
class PaymentCaller {
  final RpcCallerEndpoint _endpoint;
  
  Future<ProcessPaymentResponse> processPayment(ProcessPaymentRequest request) async {
    // Критически важные операции требуют явного управления таймаутами
    return await _endpoint.unaryRequest<ProcessPaymentRequest, ProcessPaymentResponse>(
      serviceName: 'PaymentService',
      methodName: 'processPayment',
      requestCodec: ProcessPaymentRequest.codec,
      responseCodec: ProcessPaymentResponse.codec,
      request: request,
    ).timeout(
      Duration(seconds: 30), // Разумный таймаут для финансовых операций
      onTimeout: () => throw PaymentTimeoutException('Payment processing timeout'),
    );
  }
  
  // Разные операции могут требовать разных таймаутов
  Future<ValidateCardResponse> validateCard(ValidateCardRequest request) async {
    return await _endpoint.unaryRequest<ValidateCardRequest, ValidateCardResponse>(
      serviceName: 'PaymentService',
      methodName: 'validateCard',
      requestCodec: ValidateCardRequest.codec,
      responseCodec: ValidateCardResponse.codec,
      request: request,
    ).timeout(
      Duration(seconds: 5), // Быстрая операция валидации
      onTimeout: () => throw CardValidationTimeoutException('Card validation timeout'),
    );
  }
}
```

## Паттерны тестирования

### Тестовые фабрики для CORD объектов

Тестовые фабрики полезны в CORD, так как Request/Response объекты могут быть сложными.

```dart
class TestDataFactory {
  static CreateOrderRequest createOrderRequest({
    String userId = 'test_user',
    List<OrderItem>? items,
    DeliveryAddress? deliveryAddress,
  }) {
    return CreateOrderRequest(
      userId: userId,
      items: items ?? [
        OrderItem(productId: 'product_1', quantity: 1, price: 100.0),
        OrderItem(productId: 'product_2', quantity: 2, price: 50.0),
      ],
      deliveryAddress: deliveryAddress ?? DeliveryAddress(
        street: 'Test Street 123',
        city: 'Test City',
        postalCode: '12345',
      ),
    );
  }
  
  static ProcessPaymentResponse successfulPayment({
    String? transactionId,
  }) {
    return ProcessPaymentResponse(
      isSuccessful: true,
      transactionId: transactionId ?? 'txn_${DateTime.now().millisecondsSinceEpoch}',
    );
  }
  
  static ProcessPaymentResponse failedPayment({
    String errorMessage = 'Insufficient funds',
  }) {
    return ProcessPaymentResponse(
      isSuccessful: false,
      errorMessage: errorMessage,
    );
  }
}

// Использование в тестах упрощает создание тестовых сценариев
void main() {
  group('OrderResponder Tests', () {
    test('should handle order creation with custom data', () async {
  final request = TestDataFactory.createOrderRequest(
    userId: 'custom_user',
    items: [OrderItem(productId: 'special_product', quantity: 5, price: 200.0)],
  );
  
  when(() => mockPayments.processPayment(any()))
      .thenAnswer((_) async => TestDataFactory.successfulPayment());
  
  final response = await orderResponder.createOrder(request);
  expect(response.order.userId, equals('custom_user'));
});

test('should handle payment failure gracefully', () async {
  final request = TestDataFactory.createOrderRequest();
  
  when(() => mockPayments.processPayment(any()))
      .thenAnswer((_) async => TestDataFactory.failedPayment(
        errorMessage: 'Card declined',
      ));
  
  expect(
    () => orderResponder.createOrder(request),
    throwsA(isA<OrderCreationException>().having(
      (e) => e.message,
      'message',
      contains('Card declined'),
    )),
  );
    });
  });
}
```

### Моки с различными сценариями

```dart
class MockScenarios {
  static void setupSuccessfulInventoryCheck(MockInventoryCaller mock) {
    when(() => mock.checkAvailability(any()))
        .thenAnswer((_) async => CheckAvailabilityResponse(allAvailable: true));
  }
  
  static void setupOutOfStockInventory(MockInventoryCaller mock, List<String> unavailableProducts) {
    when(() => mock.checkAvailability(any()))
        .thenAnswer((_) async => CheckAvailabilityResponse(
          allAvailable: false,
          unavailableProducts: unavailableProducts,
        ));
  }
  
  static void setupPaymentServiceError(MockPaymentCaller mock) {
    when(() => mock.processPayment(any()))
        .thenThrow(RpcException('Payment service unavailable'));
  }
}

// Использование в тестах
test('should handle inventory shortage', () async {
  MockScenarios.setupOutOfStockInventory(mockInventory, ['product_1']);
  
  final request = TestDataFactory.createOrderRequest();
  
  expect(
    () => orderResponder.createOrder(request),
    throwsA(isA<OrderCreationException>().having(
      (e) => e.message,
      'message',
      contains('product_1'),
    )),
  );
});
```

## Общие анти-паттерны в CORD контексте

### Избегайте CRUD-доменов

```dart
// Неправильно: домен как простое хранилище данных
abstract interface class IUserContract implements IRpcContract {
  Future<SaveUserResponse> saveUser(SaveUserRequest request);
  Future<LoadUserResponse> loadUser(LoadUserRequest request);
  Future<DeleteUserResponse> deleteUser(DeleteUserRequest request);
}

// Правильно: домен содержит бизнес-операции
abstract interface class IUserContract implements IRpcContract {
  Future<RegisterUserResponse> registerUser(RegisterUserRequest request);
  Future<AuthenticateResponse> authenticate(AuthenticateRequest request);
  Future<ChangePasswordResponse> changePassword(ChangePasswordRequest request);
  Future<DeactivateAccountResponse> deactivateAccount(DeactivateAccountRequest request);
}
```

### Избегайте монолитных контрактов

```dart
// Неправильно: один контракт для всех операций приложения
abstract interface class IApplicationContract implements IRpcContract {
  // User operations
  Future<RegisterUserResponse> registerUser(RegisterUserRequest request);
  Future<LoginResponse> login(LoginRequest request);
  
  // Order operations  
  Future<CreateOrderResponse> createOrder(CreateOrderRequest request);
  Future<CancelOrderResponse> cancelOrder(CancelOrderRequest request);
  
  // Payment operations
  Future<ProcessPaymentResponse> processPayment(ProcessPaymentRequest request);
  
  // Notification operations
  Future<SendEmailResponse> sendEmail(SendEmailRequest request);
  
  // Analytics operations
  Future<GetAnalyticsResponse> getAnalytics(GetAnalyticsRequest request);
}

// Правильно: фокусированные контракты для каждого домена
abstract interface class IUserContract implements IRpcContract {
  Future<RegisterUserResponse> registerUser(RegisterUserRequest request);
  Future<LoginResponse> login(LoginRequest request);
}

abstract interface class IOrderContract implements IRpcContract {
  Future<CreateOrderResponse> createOrder(CreateOrderRequest request);
  Future<CancelOrderResponse> cancelOrder(CancelOrderRequest request);
}
```

## Заключение

Применение практик программирования в CORD требует понимания специфики архитектуры:

- **Контракты** должны быть стабильными и эволюционировать осторожно
- **RPC операции** требуют особого внимания к таймаутам и обработке ошибок
- **Caller'ы** - естественное место для кэширования и оптимизаций
- **Тестирование** упрощается благодаря четкому разделению зависимостей

Эти практики приобретают особенности в контексте междоменных взаимодействий через RPC. 