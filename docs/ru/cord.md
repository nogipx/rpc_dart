# CORD: Contract-Oriented Remote Domains

> **Эксперимент с изоляцией доменов через RPC**

## Содержание

1. [Введение](#введение)
2. [Техническое описание CORD](#техническое-описание-cord)
3. [Архитектурные компоненты](#архитектурные-компоненты)
4. [Транспортные механизмы](#транспортные-механизмы)
5. [Практический пример](#практический-пример)
6. [Заключение](#заключение)

---

## Введение

**CORD (Contract-Oriented Remote Domains)** — архитектурный подход для структурирования Flutter-приложений через изоляцию бизнес-доменов с типизированными контрактами взаимодействия.

### Что это такое

CORD предлагает декомпозировать приложение не по техническим слоям (UI → Business Logic → Data), а по **бизнес-доменам**, где каждый домен функционирует как независимый сервис с формальным API.

### Что это НЕ

- Не серебряная пуля для всех архитектурных проблем
- Не замена существующим подходам для простых приложений
- Не готовое решение без накладных расходов
- Не микросервисы в традиционном понимании

## Техническое описание CORD

### Основная идея

Каждый бизнес-домен инкапсулируется как независимый сервис, взаимодействующий с другими доменами исключительно через типизированные RPC вызовы.

### Ключевые принципы

1. **Contract-First**: Все взаимодействия определяются через типизированные контракты
2. **Domain Isolation**: Домены не имеют прямых зависимостей друг от друга
3. **Transport Agnostic**: Код доменов не зависит от способа их выполнения (локально/удаленно)

### Архитектурная модель

```
Domain A ←→ [RPC Contract] ←→ Domain B
    ↕                           ↕
[Transport Layer]         [Transport Layer]
    ↕                           ↕
Endpoint A              Endpoint B
```

## Архитектурные компоненты

### 1. Contract (Контракт)

**Назначение:** Определяет API домена через набор операций.

```dart
abstract interface class IUserContract {
  Future<GetUserResponse> getUser(GetUserRequest request);
  Future<UpdateUserResponse> updateUser(UpdateUserRequest request);
  Stream<UserEvent> subscribeToUserEvents(UserEventsRequest request);
}
```

**Характеристики:**
- Типизированные Request/Response объекты
- Поддержка унарных и потоковых операций
- Независимость от транспортного механизма

### 2. Responder (Реализация домена)

**Назначение:** Содержит бизнес-логику домена и реализует контракт.

```dart
class UserResponder implements IUserContract {
  final PaymentCaller _payments;  // Зависимость от другого домена
  final UserRepository _repository;  // Локальные ресурсы
  
  UserResponder({
    required PaymentCaller payments,
    required UserRepository repository,
  }) : _payments = payments, _repository = repository;
  
  @override
  Future<GetUserResponse> getUser(GetUserRequest request) async {
    final user = await _repository.findById(request.userId);
    // Междоменный вызов при необходимости
    final paymentInfo = await _payments.getUserPaymentInfo(
      GetPaymentInfoRequest(userId: request.userId)
    );
    return GetUserResponse(user: user, paymentInfo: paymentInfo);
  }
}
```

**Принципы:**
- Получает зависимости от других доменов через Caller'ы в конструкторе
- Содержит только бизнес-логику своего домена
- Взаимодействует с другими доменами только через RPC

### 3. Caller (Клиент домена)

**Назначение:** Предоставляет типобезопасный способ вызова методов домена.

```dart
class UserCaller extends RpcCallerContract implements IUserContract {
  UserCaller(RpcCallerEndpoint endpoint) : super(endpoint);

  @override
  Future<GetUserResponse> getUser(GetUserRequest request) {
    return endpoint.unaryRequest<GetUserRequest, GetUserResponse>(
      serviceName: serviceName,
      methodName: 'getUser',
      requestCodec: GetUserRequest.codec,
      responseCodec: GetUserResponse.codec,
      request: request,
    );
  }
}
```

**Принципы:**
- Зеркальная реализация контракта для клиентской стороны
- Инкапсулирует детали RPC вызовов
- Обеспечивает типобезопасность на этапе компиляции

## Транспортные механизмы

### InMemory Transport

**Характеристики:**
- Прямая связь между Caller'ами и Responder'ами в одном процессе
- Сериализация через CBOR
- Минимальные накладные расходы

```dart
// Создание парных endpoints
final (clientTransport, serverTransport) = RpcInMemoryTransport.pair();
final endpoint = RpcCallerEndpoint(transport: clientTransport);
final userCaller = UserCaller(endpoint);
```

### Расширяемая архитектура транспортов

CORD поддерживает подключение различных транспортных механизмов:

- **Process isolation** — изоляция доменов в отдельных процессах
- **Network transports** — распределенное выполнение доменов  
- **Message queues** — асинхронная коммуникация

**Принцип:** Код доменов остается неизменным при смене транспорта.

## Практический пример

Простой пример создания заказа с взаимодействием двух доменов:

```dart
// 1. Контракт домена заказов
abstract interface class IOrderContract {
  Future<CreateOrderResponse> createOrder(CreateOrderRequest request);
}

// 2. Responder содержит логику домена
class OrderResponder implements IOrderContract {
  final UserCaller _users;  // Зависимость от другого домена
  
  OrderResponder({required UserCaller users}) : _users = users;
  
  @override
  Future<CreateOrderResponse> createOrder(CreateOrderRequest request) async {
    // Получаем пользователя из другого домена
    final user = await _users.getUser(GetUserRequest(id: request.userId));
    
    // Бизнес-логика создания заказа
    final order = Order(
      id: generateId(),
      userId: user.user.id,
      items: request.items,
      status: OrderStatus.pending,
    );
    
    return CreateOrderResponse(order: order);
  }
}

// 3. Caller для вызова из UI
class OrderCaller extends RpcCallerContract implements IOrderContract {
  OrderCaller(RpcCallerEndpoint endpoint) : super(endpoint);

  @override
  Future<CreateOrderResponse> createOrder(CreateOrderRequest request) {
    return endpoint.unaryRequest<CreateOrderRequest, CreateOrderResponse>(
      serviceName: 'OrderService',
      methodName: 'createOrder',
      requestCodec: CreateOrderRequest.codec,
      responseCodec: CreateOrderResponse.codec,
      request: request,
    );
  }
}

// 4. Использование в UI через BLoC
class OrderBloc extends Bloc<OrderEvent, OrderState> {
  final OrderCaller _orders;
  
  OrderBloc({required OrderCaller orders}) : _orders = orders;
  
  Future<void> _createOrder(CreateOrderEvent event, Emitter emit) async {
    emit(OrderLoading());
    try {
      final result = await _orders.createOrder(
        CreateOrderRequest(userId: event.userId, items: event.items)
      );
      emit(OrderSuccess(result.order));
    } catch (e) {
      emit(OrderError(e.toString()));
    }
  }
}
```


## Заключение

CORD - это эксперимент с идеей изоляции бизнес-доменов через RPC границы. Основная ценность в том, что междоменные взаимодействия становятся явными и типизированными.

Может быть полезен для сложных приложений с множественными доменами, но требует дополнительного кода для контрактов и сериализации.

---

*Экспериментальная идея. Всё может измениться.* 