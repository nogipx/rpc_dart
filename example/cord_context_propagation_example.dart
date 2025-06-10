// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: LGPL-3.0-or-later
import 'package:rpc_dart/rpc_dart.dart';

/// Пример Context Propagation в CORD архитектуре
///
/// Демонстрирует explicit передачу контекста через цепочку доменов:
/// UI → OrderDomain → UserDomain → PaymentDomain
///
/// Каждый домен наследует trace ID и создает свой собственный request ID

void main() async {
  await cordContextPropagationDemo();
}

Future<void> cordContextPropagationDemo() async {
  print('🔗 CORD Context Propagation Demo\n');

  // Настройка транспорта и endpoints
  final (clientTransport, serverTransport) = RpcInMemoryTransport.pair();

  final serverEndpoint = RpcResponderEndpoint(transport: serverTransport);
  final clientEndpoint = RpcCallerEndpoint(transport: clientTransport);

  // Регистрируем CORD домены
  serverEndpoint.registerServiceContract(OrderResponder(
    userCaller: UserCaller('UserService', clientEndpoint),
    paymentCaller: PaymentCaller('PaymentService', clientEndpoint),
  ));
  serverEndpoint.registerServiceContract(UserResponder());
  serverEndpoint.registerServiceContract(PaymentResponder());

  serverEndpoint.start();

  // Создаем order caller для UI
  final orderCaller = OrderCaller('OrderService', clientEndpoint);

  print('📋 Создание заказа с explicit context propagation...\n');

  // 🎯 Phase 1: UI создает бизнес-операцию
  final businessContext = RpcContextPropagation.forBusinessOperation(
    operationType: 'CreateOrder',
    userId: 'user_12345',
    sessionId: 'session_67890',
    tenantId: 'tenant_abc',
  );

  print('✅ Создан бизнес-контекст:');
  print('   Trace ID: ${businessContext.traceId}');
  print('   Request ID: ${businessContext.requestId}');
  print('   User ID: ${businessContext.getHeader('x-user-id')}');
  print('');

  // 🎯 Phase 2: UI вызывает OrderDomain
  try {
    final result = await orderCaller.createOrder(
      CreateOrderRequest(
        userId: 'user_12345',
        items: ['item1', 'item2'],
        totalAmount: 99.99,
      ),
      context: businessContext, // Explicit передача!
    );

    print('🎉 Заказ создан: ${result.orderId}');
    print('   Статус: ${result.status}');
    print('   Сумма: \$${result.totalAmount}');
  } catch (e) {
    print('❌ Ошибка создания заказа: $e');
  }

  await serverEndpoint.close();
  await clientEndpoint.close();
}

// === CORD DOMAINS ===

/// Order Domain - координирует создание заказа
base class OrderResponder extends RpcResponderContract with RpcContextAware {
  final UserCaller _userCaller;
  final PaymentCaller _paymentCaller;

  OrderResponder({
    required UserCaller userCaller,
    required PaymentCaller paymentCaller,
  })  : _userCaller = userCaller,
        _paymentCaller = paymentCaller,
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

  Future<CreateOrderResponse> createOrder(
    CreateOrderRequest request, {
    RpcContext? context,
  }) async {
    // Обновляем контекст для RpcContextAware mixin
    updateCurrentContext(context);

    print('📦 [OrderDomain] Получен запрос на создание заказа');
    if (context != null) {
      final metadata = RpcContextPropagation.extractDomainMetadata(context);
      print('   Context: $metadata');
    }

    try {
      // 🔄 Междоменный вызов 1: UserDomain
      final userContext = createCallContext(
        targetDomain: 'UserDomain',
        operation: 'GetUser',
        timeout: Duration(seconds: 5),
      );

      print(
          '   → Вызов UserDomain с context: trace=${userContext.traceId}, req=${userContext.requestId}');

      final userResponse = await _userCaller.getUser(
        GetUserRequest(userId: request.userId),
        context: userContext, // Explicit propagation!
      );

      if (!userResponse.exists) {
        throw Exception('User not found: ${request.userId}');
      }

      // 🔄 Междоменный вызов 2: PaymentDomain
      final paymentContext = createCallContext(
        targetDomain: 'PaymentDomain',
        operation: 'ProcessPayment',
        timeout: Duration(seconds: 10),
      );

      print(
          '   → Вызов PaymentDomain с context: trace=${paymentContext.traceId}, req=${paymentContext.requestId}');

      final paymentResponse = await _paymentCaller.processPayment(
        ProcessPaymentRequest(
          userId: request.userId,
          amount: request.totalAmount,
          currency: 'USD',
        ),
        context: paymentContext, // Explicit propagation!
      );

      if (!paymentResponse.success) {
        throw Exception('Payment failed: ${paymentResponse.errorMessage}');
      }

      // Создаем заказ
      final orderId = 'order_${DateTime.now().millisecondsSinceEpoch}';

      print('✅ [OrderDomain] Заказ создан успешно: $orderId');

      return CreateOrderResponse(
        orderId: orderId,
        status: 'created',
        totalAmount: request.totalAmount,
        userId: request.userId,
      );
    } catch (e) {
      print('❌ [OrderDomain] Ошибка: $e');
      rethrow;
    }
  }
}

/// User Domain - управляет пользователями
base class UserResponder extends RpcResponderContract {
  UserResponder() : super('UserService');

  @override
  void setup() {
    addUnaryMethod<GetUserRequest, GetUserResponse>(
      methodName: 'getUser',
      handler: getUser,
      requestCodec: GetUserRequest.codec,
      responseCodec: GetUserResponse.codec,
    );
  }

  Future<GetUserResponse> getUser(
    GetUserRequest request, {
    RpcContext? context,
  }) async {
    print('👤 [UserDomain] Поиск пользователя: ${request.userId}');
    if (context != null) {
      final metadata = RpcContextPropagation.extractDomainMetadata(context);
      print('   Context: $metadata');
    }

    // Симуляция поиска пользователя
    await Future.delayed(Duration(milliseconds: 100));

    return GetUserResponse(
      userId: request.userId,
      userName: 'John Doe',
      email: 'john@example.com',
      exists: true,
    );
  }
}

/// Payment Domain - обрабатывает платежи
base class PaymentResponder extends RpcResponderContract {
  PaymentResponder() : super('PaymentService');

  @override
  void setup() {
    addUnaryMethod<ProcessPaymentRequest, ProcessPaymentResponse>(
      methodName: 'processPayment',
      handler: processPayment,
      requestCodec: ProcessPaymentRequest.codec,
      responseCodec: ProcessPaymentResponse.codec,
    );
  }

  Future<ProcessPaymentResponse> processPayment(
    ProcessPaymentRequest request, {
    RpcContext? context,
  }) async {
    print('💳 [PaymentDomain] Обработка платежа: \$${request.amount}');
    if (context != null) {
      final metadata = RpcContextPropagation.extractDomainMetadata(context);
      print('   Context: $metadata');
    }

    // Симуляция обработки платежа
    await Future.delayed(Duration(milliseconds: 200));

    return ProcessPaymentResponse(
      transactionId: 'tx_${DateTime.now().millisecondsSinceEpoch}',
      success: true,
      amount: request.amount,
      currency: request.currency,
    );
  }
}

// === CALLERS ===

base class OrderCaller extends RpcCallerContract {
  OrderCaller(super.serviceName, super.endpoint);

  Future<CreateOrderResponse> createOrder(
    CreateOrderRequest request, {
    RpcContext? context,
  }) {
    return callUnary<CreateOrderRequest, CreateOrderResponse>(
      methodName: 'createOrder',
      requestCodec: CreateOrderRequest.codec,
      responseCodec: CreateOrderResponse.codec,
      request: request,
      context: context,
    );
  }
}

base class UserCaller extends RpcCallerContract {
  UserCaller(super.serviceName, super.endpoint);

  Future<GetUserResponse> getUser(
    GetUserRequest request, {
    RpcContext? context,
  }) {
    return callUnary<GetUserRequest, GetUserResponse>(
      methodName: 'getUser',
      requestCodec: GetUserRequest.codec,
      responseCodec: GetUserResponse.codec,
      request: request,
      context: context,
    );
  }
}

base class PaymentCaller extends RpcCallerContract {
  PaymentCaller(super.serviceName, super.endpoint);

  Future<ProcessPaymentResponse> processPayment(
    ProcessPaymentRequest request, {
    RpcContext? context,
  }) {
    return callUnary<ProcessPaymentRequest, ProcessPaymentResponse>(
      methodName: 'processPayment',
      requestCodec: ProcessPaymentRequest.codec,
      responseCodec: ProcessPaymentResponse.codec,
      request: request,
      context: context,
    );
  }
}

// === MODELS ===

class CreateOrderRequest implements IRpcSerializable {
  final String userId;
  final List<String> items;
  final double totalAmount;

  CreateOrderRequest({
    required this.userId,
    required this.items,
    required this.totalAmount,
  });

  @override
  Map<String, dynamic> toJson() => {
        'userId': userId,
        'items': items,
        'totalAmount': totalAmount,
      };

  static CreateOrderRequest fromJson(Map<String, dynamic> json) =>
      CreateOrderRequest(
        userId: json['userId'],
        items: List<String>.from(json['items']),
        totalAmount: json['totalAmount'],
      );

  static RpcCodec<CreateOrderRequest> get codec =>
      RpcCodec(CreateOrderRequest.fromJson);
}

class CreateOrderResponse implements IRpcSerializable {
  final String orderId;
  final String status;
  final double totalAmount;
  final String userId;

  CreateOrderResponse({
    required this.orderId,
    required this.status,
    required this.totalAmount,
    required this.userId,
  });

  @override
  Map<String, dynamic> toJson() => {
        'orderId': orderId,
        'status': status,
        'totalAmount': totalAmount,
        'userId': userId,
      };

  static CreateOrderResponse fromJson(Map<String, dynamic> json) =>
      CreateOrderResponse(
        orderId: json['orderId'],
        status: json['status'],
        totalAmount: json['totalAmount'],
        userId: json['userId'],
      );

  static RpcCodec<CreateOrderResponse> get codec =>
      RpcCodec(CreateOrderResponse.fromJson);
}

class GetUserRequest implements IRpcSerializable {
  final String userId;

  GetUserRequest({required this.userId});

  @override
  Map<String, dynamic> toJson() => {'userId': userId};

  static GetUserRequest fromJson(Map<String, dynamic> json) =>
      GetUserRequest(userId: json['userId']);

  static RpcCodec<GetUserRequest> get codec =>
      RpcCodec(GetUserRequest.fromJson);
}

class GetUserResponse implements IRpcSerializable {
  final String userId;
  final String userName;
  final String email;
  final bool exists;

  GetUserResponse({
    required this.userId,
    required this.userName,
    required this.email,
    required this.exists,
  });

  @override
  Map<String, dynamic> toJson() => {
        'userId': userId,
        'userName': userName,
        'email': email,
        'exists': exists,
      };

  static GetUserResponse fromJson(Map<String, dynamic> json) => GetUserResponse(
        userId: json['userId'],
        userName: json['userName'],
        email: json['email'],
        exists: json['exists'],
      );

  static RpcCodec<GetUserResponse> get codec =>
      RpcCodec(GetUserResponse.fromJson);
}

class ProcessPaymentRequest implements IRpcSerializable {
  final String userId;
  final double amount;
  final String currency;

  ProcessPaymentRequest({
    required this.userId,
    required this.amount,
    required this.currency,
  });

  @override
  Map<String, dynamic> toJson() => {
        'userId': userId,
        'amount': amount,
        'currency': currency,
      };

  static ProcessPaymentRequest fromJson(Map<String, dynamic> json) =>
      ProcessPaymentRequest(
        userId: json['userId'],
        amount: json['amount'],
        currency: json['currency'],
      );

  static RpcCodec<ProcessPaymentRequest> get codec =>
      RpcCodec(ProcessPaymentRequest.fromJson);
}

class ProcessPaymentResponse implements IRpcSerializable {
  final String transactionId;
  final bool success;
  final double amount;
  final String currency;
  final String? errorMessage;

  ProcessPaymentResponse({
    required this.transactionId,
    required this.success,
    required this.amount,
    required this.currency,
    this.errorMessage,
  });

  @override
  Map<String, dynamic> toJson() => {
        'transactionId': transactionId,
        'success': success,
        'amount': amount,
        'currency': currency,
        if (errorMessage != null) 'errorMessage': errorMessage,
      };

  static ProcessPaymentResponse fromJson(Map<String, dynamic> json) =>
      ProcessPaymentResponse(
        transactionId: json['transactionId'],
        success: json['success'],
        amount: json['amount'],
        currency: json['currency'],
        errorMessage: json['errorMessage'],
      );

  static RpcCodec<ProcessPaymentResponse> get codec =>
      RpcCodec(ProcessPaymentResponse.fromJson);
}
