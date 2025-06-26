# CORD Best Practices

> **Recommendations for using Contract-Oriented Remote Domains**

> 📖 **See also:** [CORD General Practices](cord_general_practices.md) - applying classical programming practices in the context of CORD architecture

## Table of Contents

- [Domain Design](#domain-design)
- [Domain Classification](#domain-classification)
- [Contract Design](#contract-design)
- [Responder Implementation](#responder-implementation)
- [Working with Callers](#working-with-callers)
- [UI Layer and State Management](#ui-layer-and-state-management)
- [Testing](#testing)
- [Anti-patterns](#anti-patterns)

## Domain Design

### Single Responsibility Principle for Domains

**Recommended approach:** Each domain should be responsible for one clearly defined business area.

```dart
// Recommended: clear domain boundaries
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

**Wrong approach:** Mixed responsibilities
```dart
// Not recommended: violation of single responsibility principle
abstract interface class IUserNotificationContract implements IRpcContract {
  Future<GetProfileResponse> getProfile(GetProfileRequest request);
  Future<SendEmailResponse> sendEmail(SendEmailRequest request);
  Future<ValidatePaymentResponse> validatePayment(ValidatePaymentRequest request);
}
```

## Domain Classification

In CORD architecture, domains are classified into two main categories: **business domains** and **infrastructure domains**.

### Business Domains

**Purpose:** Contain domain logic that is directly related to business requirements and domain rules.

**Characteristics:**
- Represent specific business areas (users, orders, payments)
- Contain domain logic and business rules
- Can interact with other business domains through RPC
- Use infrastructure domains for technical operations

```dart
// Example of business domain
abstract interface class IOrderContract implements IRpcContract {
  Future<CreateOrderResponse> createOrder(CreateOrderRequest request);
  Future<CancelOrderResponse> cancelOrder(CancelOrderRequest request);
  Future<GetOrderStatusResponse> getOrderStatus(GetOrderStatusRequest request);
}

final class OrderResponder extends RpcResponderContract implements IOrderContract {
  final PaymentCaller _payments;           // Another business domain
  final InventoryCaller _inventory;        // Another business domain
  final LocalNotificationCaller _notifications; // Infrastructure domain
  final LoggingCaller _logging;            // Infrastructure domain
  
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
    // Business logic
    final availability = await _inventory.checkAvailability(
      CheckAvailabilityRequest(productIds: request.items.map((e) => e.id).toList()),
    );
    
    final payment = await _payments.processPayment(
      ProcessPaymentRequest(amount: request.total, method: request.paymentMethod),
    );
    
    final order = Order.create(request, payment);
    
    // Using infrastructure domains
    await _notifications.showNotification(ShowNotificationRequest(
      title: 'Order created',
      message: 'Order #${order.id} successfully created',
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

### Infrastructure Domains

**Purpose:** Provide technical functionality that is reused by various business domains.

**Characteristics:**
- Encapsulate technical aspects (notifications, caching, logging)
- Don't contain business logic
- Provide stable APIs for technical operations
- Can have platform-specific implementations

```dart
// Examples of infrastructure domains

// Local notifications
abstract interface class ILocalNotificationContract implements IRpcContract {
  Future<ShowNotificationResponse> showNotification(ShowNotificationRequest request);
  Future<ScheduleNotificationResponse> scheduleNotification(ScheduleNotificationRequest request);
  Future<CancelNotificationResponse> cancelNotification(CancelNotificationRequest request);
  Stream<NotificationInteractionEvent> subscribeToInteractions();
}

// Caching
abstract interface class ICacheContract implements IRpcContract {
  Future<SetCacheResponse> set(SetCacheRequest request);
  Future<GetCacheResponse> get(GetCacheRequest request);
  Future<DeleteCacheResponse> delete(DeleteCacheRequest request);
  Future<ClearCacheResponse> clear(ClearCacheRequest request);
}

// Navigation
abstract interface class INavigationContract implements IRpcContract {
  Future<NavigateToResponse> navigateTo(NavigateToRequest request);
  Future<GoBackResponse> goBack(GoBackRequest request);
  Future<ReplaceRouteResponse> replaceRoute(ReplaceRouteRequest request);
  Stream<NavigationEvent> subscribeToNavigation();
}

// Logging
abstract interface class ILoggingContract implements IRpcContract {
  Future<LogEventResponse> logEvent(LogEventRequest request);
  Future<LogErrorResponse> logError(LogErrorRequest request);
  Future<SetLogLevelResponse> setLogLevel(SetLogLevelRequest request);
}
```

### Interaction Between Domain Types

**Interaction rules:**
1. **Business domains → Business domains:** Through RPC for business process coordination
2. **Business domains → Infrastructure domains:** Through RPC for technical operations
3. **Infrastructure domains → Business domains:** Not recommended (dependency inversion)
4. **Infrastructure domains → Infrastructure domains:** Rarely, only for composition

```dart
final class AnalyticsResponder extends RpcResponderContract implements IAnalyticsContract {
  final CacheCaller _cache;           // Infrastructure domain
  final LoggingCaller _logging;       // Infrastructure domain
  final StorageCaller _storage;       // Infrastructure domain
  
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
    // Check cache
    final cached = await _cache.get(CacheKeyRequest(key: 'user_${request.userId}'));
    
    // Save event
    await _storage.saveEvent(SaveEventRequest(
      event: AnalyticsEvent.fromRequest(request),
      timestamp: DateTime.now(),
    ));
    
    // Log
    await _logging.logEvent(LogEventRequest(
      level: LogLevel.debug,
      message: 'Analytics event tracked: ${request.eventName}',
    ));
    
    return TrackEventResponse(success: true);
  }
}
```

## Conclusion

Applying CORD architecture with rpc_dart is based on the following principles:

1. **Clear separation of responsibilities** — each domain has a single business area
2. **Formal contracts** — domains interact only through typed RPC calls
3. **Transport independence** — one code works with InMemory, Isolate, HTTP transports
4. **Dependency Injection** — Callers are passed through constructor for testability
5. **Common endpoint** — all Callers use one endpoint for cross-domain communication

CORD is an architectural approach for applications with multiple domains. For simple CRUD applications, traditional patterns may be more suitable.

*Architectural decisions should match the complexity and requirements of the specific project* 