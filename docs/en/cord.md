# CORD: Contract-Oriented Remote Domains

> **Experiment with domain isolation through RPC**

## Table of Contents

1. [Introduction](#introduction)
2. [Technical Description of CORD](#technical-description-of-cord)
3. [Architectural Components](#architectural-components)
4. [Transport Mechanisms](#transport-mechanisms)
5. [Practical Example](#practical-example)
6. [Conclusion](#conclusion)

---

## Introduction

**CORD (Contract-Oriented Remote Domains)** — an architectural approach for structuring Flutter applications through business domain isolation with typed interaction contracts.

### What it is

CORD proposes decomposing applications not by technical layers (UI → Business Logic → Data), but by **business domains**, where each domain functions as an independent service with a formal API.

### What it is NOT

- Not a silver bullet for all architectural problems
- Not a replacement for existing approaches in simple applications
- Not a ready solution without overhead
- Not microservices in the traditional sense

## Technical Description of CORD

### Main Idea

Each business domain is encapsulated as an independent service, interacting with other domains exclusively through typed RPC calls.

### Key Principles

1. **Contract-First**: All interactions are defined through typed contracts
2. **Domain Isolation**: Domains have no direct dependencies on each other
3. **Transport Agnostic**: Domain code doesn't depend on how they're executed (locally/remotely)

### Architectural Model

```
Domain A ←→ [RPC Contract] ←→ Domain B
    ↕                           ↕
[Transport Layer]         [Transport Layer]
    ↕                           ↕
Endpoint A              Endpoint B
```

## Architectural Components

### 1. Contract

**Purpose:** Defines domain API through a set of operations.

```dart
abstract interface class IUserContract {
  Future<GetUserResponse> getUser(GetUserRequest request);
  Future<UpdateUserResponse> updateUser(UpdateUserRequest request);
  Stream<UserEvent> subscribeToUserEvents(UserEventsRequest request);
}
```

**Characteristics:**
- Typed Request/Response objects
- Support for unary and streaming operations
- Independence from transport mechanism

### 2. Responder (Domain Implementation)

**Purpose:** Contains domain business logic and implements the contract.

```dart
class UserResponder implements IUserContract {
  final PaymentCaller _payments;  // Dependency on another domain
  final UserRepository _repository;  // Local resources
  
  UserResponder({
    required PaymentCaller payments,
    required UserRepository repository,
  }) : _payments = payments, _repository = repository;
  
  @override
  Future<GetUserResponse> getUser(GetUserRequest request) async {
    final user = await _repository.findById(request.userId);
    // Cross-domain call when necessary
    final paymentInfo = await _payments.getUserPaymentInfo(
      GetPaymentInfoRequest(userId: request.userId)
    );
    return GetUserResponse(user: user, paymentInfo: paymentInfo);
  }
}
```

**Principles:**
- Receives dependencies from other domains through Callers in constructor
- Contains only business logic of its own domain
- Interacts with other domains only through RPC

### 3. Caller (Domain Client)

**Purpose:** Provides type-safe way to call domain methods.

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

**Principles:**
- Mirror implementation of contract for client side
- Encapsulates RPC call details
- Ensures type safety at compile time

## Transport Mechanisms

### InMemory Transport

**Characteristics:**
- Direct connection between Callers and Responders in single process
- Serialization through CBOR
- Minimal overhead

```dart
// Creating paired endpoints
final (clientTransport, serverTransport) = RpcInMemoryTransport.pair();
final endpoint = RpcCallerEndpoint(transport: clientTransport);
final userCaller = UserCaller(endpoint);
```

### Extensible Transport Architecture

CORD supports connecting various transport mechanisms:

- **Process isolation** — isolating domains in separate processes
- **Network transports** — distributed domain execution  
- **Message queues** — asynchronous communication

**Principle:** Domain code remains unchanged when switching transports.

## Practical Example

Simple example of creating an order with interaction between two domains:

```dart
// 1. Order domain contract
abstract interface class IOrderContract {
  Future<CreateOrderResponse> createOrder(CreateOrderRequest request);
}

// 2. Responder contains domain logic
class OrderResponder implements IOrderContract {
  final UserCaller _users;  // Dependency on another domain
  
  OrderResponder({required UserCaller users}) : _users = users;
  
  @override
  Future<CreateOrderResponse> createOrder(CreateOrderRequest request) async {
    // Get user from another domain
    final user = await _users.getUser(GetUserRequest(id: request.userId));
    
    // Business logic for order creation
    final order = Order(
      id: generateId(),
      userId: user.user.id,
      items: request.items,
      status: OrderStatus.pending,
    );
    
    return CreateOrderResponse(order: order);
  }
}

// 3. Caller for UI calls
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

// 4. Usage in UI through BLoC
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

## Conclusion

CORD is an experiment with the idea of business domain isolation through RPC boundaries. The main value is that cross-domain interactions become explicit and typed.

Can be useful for complex applications with multiple domains, but requires additional code for contracts and serialization.

---

*Experimental idea. Everything can change.* 