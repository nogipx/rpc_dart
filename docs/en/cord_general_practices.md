# CORD General Practices

> **Programming practices in the context of Contract-Oriented Remote Domains**

How to apply commonly accepted programming practices when working with CORD architecture.

> 📚 **See also:** [CORD Architecture Overview](cord_architecture_overview.md) and [CORD Best Practices](cord_best_practices.md)

## Table of Contents

- [Data Design Principles](#data-design-principles)
  - [Request/Response Object Naming](#requestresponse-object-naming)
  - [Composition vs Inheritance in Request/Response](#composition-vs-inheritance-in-requestresponse)
  - [Immutability in Cross-Domain Calls](#immutability-in-cross-domain-calls)
- [Validation and Error Handling](#validation-and-error-handling)
- [Performance Patterns](#performance-patterns)
- [Testing Patterns](#testing-patterns)
- [Common Anti-patterns in CORD Context](#common-anti-patterns-in-cord-context)

## Data Design Principles

### Request/Response Object Naming

In CORD contracts, clear naming is especially important since these objects serve as APIs between domains.

```dart
// Recommended: descriptive names reflect domain operation
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

// Not recommended: too generic names make contract understanding difficult
class Request extends IRpcSerializable {
  final Map<String, dynamic> data;
}

class Response extends IRpcSerializable {
  final bool success;
  final String? message;
}
```

### Composition vs Inheritance in Request/Response

In CORD, it's especially important to avoid inheritance in DTOs since base class changes can break contract compatibility.

```dart
// Recommended: composition ensures contract stability
class CreateOrderRequest extends IRpcSerializable {
  final UserInfo userInfo;         // Composition - UserInfo changes don't affect contract
  final List<OrderItem> items;
  final DeliveryOptions delivery;  // Composition - can evolve independently
  final PaymentInfo payment;       // Composition - isolated changes
}

// Not recommended: inheritance creates fragile contracts
class CreateOrderRequest extends BaseUserRequest {
  final List<OrderItem> items;
  // Changes in BaseUserRequest can break existing Callers
}
```

### Immutability in Cross-Domain Calls

```dart
// Wrong: passing mutable objects through RPC
class CreateOrderRequest extends IRpcSerializable {
  final User user;          // Mutable object - can change during processing
  final List<CartItem> items; // Mutable list - contract violation
}

// Correct: passing immutable data
class CreateOrderRequest extends IRpcSerializable {
  final String userId;      // Primitive - guaranteed immutable
  final List<String> productIds; // List of primitives - safe
  final double totalAmount; // Primitive - cannot be changed
  final String deliveryAddress; // Primitive or Value Object
}
```

## Validation and Error Handling

### Input Data Validation in Responders

In CORD, validation is especially critical since data comes through RPC and can be incorrect.

```dart
@override
Future<CreateOrderResponse> createOrder(CreateOrderRequest request) async {
  // Early validation prevents passing incorrect data down the chain
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
  
  // After validation, we can safely work with data
  final availability = await _inventory.checkAvailability(
    CheckAvailabilityRequest(productIds: request.items.map((e) => e.productId).toList()),
  );
  
  // ... rest of business logic
}
```

### Multi-level RPC Error Handling

In CORD, it's important to distinguish error types: technical (RPC), domain, and business logic.

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
      // Business logic error: payment declined
      throw OrderCreationException('Payment failed: ${payment.errorMessage}');
    }
    
  } on RpcException catch (e) {
    // Technical error: connection or serialization issues
    throw OrderCreationException('Payment service unavailable: $e');
  } on PaymentException catch (e) {
    // Domain error: payment domain business rule violation
    throw OrderCreationException('Payment validation failed: $e');
  }
  
  // ... continue business logic
}
```

## Performance Patterns

### Caching in Callers

Callers are suitable for caching since they encapsulate logic for accessing remote domains.

```dart
class UserCaller {
  final RpcCallerEndpoint _endpoint;
  final Map<String, UserProfile> _profileCache = {};
  
  UserCaller(this._endpoint);
  
  Future<GetProfileResponse> getProfile(GetProfileRequest request) async {
    // Check cache before RPC call
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
  
  // Cache invalidation on changes - important for data correctness
  Future<UpdateProfileResponse> updateProfile(UpdateProfileRequest request) async {
    final response = await _endpoint.unaryRequest<UpdateProfileRequest, UpdateProfileResponse>(
      serviceName: 'UserService',
      methodName: 'updateProfile',
      requestCodec: UpdateProfileRequest.codec,
      responseCodec: UpdateProfileResponse.codec,
      request: request,
    );
    
    // Remove stale data from cache
    _profileCache.remove(request.userId);
    
    return response;
  }
}
```

### Managing RPC Operation Timeouts

In CORD, timeout management is especially important since operations can block UI or other domains.

```dart
class PaymentCaller {
  final RpcCallerEndpoint _endpoint;
  
  Future<ProcessPaymentResponse> processPayment(ProcessPaymentRequest request) async {
    // Critical operations require explicit timeout management
    return await _endpoint.unaryRequest<ProcessPaymentRequest, ProcessPaymentResponse>(
      serviceName: 'PaymentService',
      methodName: 'processPayment',
      requestCodec: ProcessPaymentRequest.codec,
      responseCodec: ProcessPaymentResponse.codec,
      request: request,
    ).timeout(
      Duration(seconds: 30), // Reasonable timeout for financial operations
      onTimeout: () => throw PaymentTimeoutException('Payment processing timeout'),
    );
  }
  
  // Different operations may require different timeouts
  Future<ValidateCardResponse> validateCard(ValidateCardRequest request) async {
    return await _endpoint.unaryRequest<ValidateCardRequest, ValidateCardResponse>(
      serviceName: 'PaymentService',
      methodName: 'validateCard',
      requestCodec: ValidateCardRequest.codec,
      responseCodec: ValidateCardResponse.codec,
      request: request,
    ).timeout(
      Duration(seconds: 5), // Fast validation operation
      onTimeout: () => throw CardValidationTimeoutException('Card validation timeout'),
    );
  }
}
```

## Testing Patterns

### Test Factories for CORD Objects

Test factories are useful in CORD since Request/Response objects can be complex.

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

// Usage in tests simplifies test scenario creation
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

### Mocks with Different Scenarios

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

// Usage in tests
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

## Common Anti-patterns in CORD Context

### Avoid CRUD Domains

```dart
// Wrong: domain as simple data storage
abstract interface class IUserContract implements IRpcContract {
  Future<SaveUserResponse> saveUser(SaveUserRequest request);
  Future<LoadUserResponse> loadUser(LoadUserRequest request);
  Future<DeleteUserResponse> deleteUser(DeleteUserRequest request);
}

// Correct: domain contains business operations
abstract interface class IUserContract implements IRpcContract {
  Future<RegisterUserResponse> registerUser(RegisterUserRequest request);
  Future<AuthenticateResponse> authenticate(AuthenticateRequest request);
  Future<ChangePasswordResponse> changePassword(ChangePasswordRequest request);
  Future<DeactivateAccountResponse> deactivateAccount(DeactivateAccountRequest request);
}
```

### Avoid Monolithic Contracts

```dart
// Wrong: one contract for all application operations
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

// Correct: focused contracts for each domain
abstract interface class IUserContract implements IRpcContract {
  Future<RegisterUserResponse> registerUser(RegisterUserRequest request);
  Future<LoginResponse> login(LoginRequest request);
}

abstract interface class IOrderContract implements IRpcContract {
  Future<CreateOrderResponse> createOrder(CreateOrderRequest request);
  Future<CancelOrderResponse> cancelOrder(CancelOrderRequest request);
}
```

## Conclusion

Applying programming practices in CORD requires understanding architecture specifics:

- **Contracts** should be stable and evolve carefully
- **RPC operations** require special attention to timeouts and error handling
- **Callers** are natural places for caching and optimizations
- **Testing** is simplified thanks to clear dependency separation

These practices acquire specific features in the context of cross-domain interactions through RPC. 