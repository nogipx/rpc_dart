// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: LGPL-3.0-or-later

import 'package:rpc_dart/rpc_dart.dart';

/// Утилиты для CORD Context Propagation
/// Explicit подход без Zone magic
abstract final class RpcContextPropagation {
  /// Создает цепочку контекстов для последовательных междоменных вызовов
  ///
  /// Пример:
  /// ```dart
  /// final chain = RpcContextPropagation.createChain(
  ///   baseContext,
  ///   steps: ['OrderDomain', 'UserDomain', 'PaymentDomain']
  /// );
  ///
  /// final userCtx = chain['UserDomain']!;
  /// final paymentCtx = chain['PaymentDomain']!;
  /// ```
  static Map<String, RpcContext> createChain(
    RpcContext baseContext, {
    required List<String> steps,
    Duration? stepTimeout,
  }) {
    final chain = <String, RpcContext>{};
    var currentContext = baseContext;

    for (final step in steps) {
      // Создаем дочерний контекст для каждого шага
      currentContext = RpcContextBuilder.inheritFrom(currentContext).build();

      // Добавляем метаданные о текущем шаге
      currentContext = currentContext.withValue('cord.step', step);

      // Устанавливаем timeout для шага, если указан
      if (stepTimeout != null) {
        currentContext = currentContext.withTimeout(stepTimeout);
      }

      chain[step] = currentContext;
    }

    return chain;
  }

  /// Создает контекст для бизнес-операции с автоматическим trace ID
  ///
  /// Пример:
  /// ```dart
  /// final opContext = RpcContextPropagation.forBusinessOperation(
  ///   operationType: 'CreateOrder',
  ///   userId: 'user123',
  ///   sessionId: 'session456'
  /// );
  /// ```
  static RpcContext forBusinessOperation({
    required String operationType,
    String? userId,
    String? sessionId,
    String? tenantId,
    Duration? timeout,
    RpcContext? parentContext,
  }) {
    var builder = parentContext != null
        ? RpcContextBuilder.inheritFrom(parentContext)
        : RpcContextBuilder().withGeneratedTraceId();

    return builder
        .withHeader('x-operation-type', operationType)
        .withDomainMetadata(
          userId: userId,
          sessionId: sessionId,
          tenantId: tenantId,
        )
        .withTimeout(timeout ?? Duration(seconds: 30))
        .build();
  }

  /// Создает контекст для CORD междоменного вызова
  ///
  /// Пример:
  /// ```dart
  /// final domainCtx = RpcContextPropagation.forDomainCall(
  ///   parentContext: currentContext,
  ///   fromDomain: 'OrderDomain',
  ///   toDomain: 'UserDomain',
  ///   operation: 'GetUser'
  /// );
  /// ```
  static RpcContext forDomainCall({
    required RpcContext parentContext,
    required String fromDomain,
    required String toDomain,
    required String operation,
    Duration? callTimeout,
  }) {
    return RpcContextBuilder.inheritFrom(parentContext)
        .withHeader('x-from-domain', fromDomain)
        .withHeader('x-to-domain', toDomain)
        .withHeader('x-domain-operation', operation)
        .withTimeout(callTimeout ?? Duration(seconds: 10))
        .build();
  }

  /// Проверяет, является ли контекст истекшим или отмененным
  static bool isContextValid(RpcContext? context) {
    if (context == null) return false;
    return !context.isExpired && !context.isCancelled;
  }

  /// Извлекает метаданные домена из контекста
  static DomainMetadata extractDomainMetadata(RpcContext context) {
    return DomainMetadata(
      userId: context.getHeader('x-user-id'),
      sessionId: context.getHeader('x-session-id'),
      tenantId: context.getHeader('x-tenant-id'),
      fromDomain: context.getHeader('x-from-domain'),
      toDomain: context.getHeader('x-to-domain'),
      operation: context.getHeader('x-domain-operation'),
      operationType: context.getHeader('x-operation-type'),
      traceId: context.traceId,
      correlationId: context.getHeader('x-correlation-id'),
    );
  }

  /// Создает "безопасную" копию контекста без чувствительных данных
  static RpcContext sanitize(RpcContext context) {
    final sanitizedHeaders = Map<String, String>.from(context.headers);

    // Удаляем чувствительные заголовки
    sanitizedHeaders.remove('authorization');
    sanitizedHeaders.remove('x-api-key');
    sanitizedHeaders.remove('cookie');

    return RpcContextBuilder()
        .withHeaders(sanitizedHeaders)
        .withTraceId(context.traceId ?? 'sanitized-trace')
        .build();
  }
}

/// Метаданные домена, извлеченные из RPC контекста
class DomainMetadata {
  final String? userId;
  final String? sessionId;
  final String? tenantId;
  final String? fromDomain;
  final String? toDomain;
  final String? operation;
  final String? operationType;
  final String? traceId;
  final String? correlationId;

  const DomainMetadata({
    this.userId,
    this.sessionId,
    this.tenantId,
    this.fromDomain,
    this.toDomain,
    this.operation,
    this.operationType,
    this.traceId,
    this.correlationId,
  });

  @override
  String toString() {
    final parts = <String>[
      if (traceId != null) 'trace:$traceId',
      if (fromDomain != null && toDomain != null) '$fromDomain→$toDomain',
      if (operation != null) 'op:$operation',
      if (userId != null) 'user:$userId',
    ];
    return 'DomainMetadata(${parts.join(', ')})';
  }
}

/// Mixin для CORD доменов с поддержкой context propagation
///
/// Автоматически использует serviceName из RPC контрактов как имя домена.
/// Для других классов требует переопределения serviceName.
///
/// Пример использования с RPC контрактами:
/// ```dart
/// class UserResponder extends RpcResponderContract with RpcContextAware {
///   UserResponder() : super('UserService');
///
///   // serviceName автоматически = 'UserService'
///
///   Future<void> handleRequest(UserRequest request, {RpcContext? context}) async {
///     // Обновляем контекст для текущего запроса
///     updateCurrentContext(context);
///
///     // Создаем контекст для вызова другого сервиса
///     final paymentContext = createCallContext(
///       targetDomain: 'PaymentService',
///       operation: 'ProcessPayment',
///     );
///
///     final paymentCaller = PaymentCaller(endpoint);
///     await paymentCaller.callSomething(context: paymentContext);
///   }
/// }
///
/// // Для кастомных классов просто переопределите serviceName:
/// class CustomDomain with RpcContextAware {
///   @override
///   String get serviceName => 'CustomDomain';
///
///   void doSomething() {
///     updateCurrentContext(someContext);
///     // работаем с контекстом...
///   }
/// }
/// ```
mixin RpcContextAware {
  /// Приватный текущий контекст домена
  RpcContext? _currentContext;

  /// Обновляет текущий контекст для домена
  void updateCurrentContext(RpcContext? context) {
    _currentContext = context;
  }

  /// Имя сервиса/домена. Для RPC контрактов используется автоматически.
  String get serviceName;

  /// Создает дочерний контекст для вызова другого домена
  RpcContext createCallContext({
    required String targetDomain,
    required String operation,
    Duration? timeout,
  }) {
    final current = _currentContext;
    if (current == null) {
      throw StateError('No current context available for domain call');
    }

    return RpcContextPropagation.forDomainCall(
      parentContext: current,
      fromDomain: serviceName,
      toDomain: targetDomain,
      operation: operation,
      callTimeout: timeout,
    );
  }

  /// Логирует метаданные текущего контекста
  void logContextMetadata() {
    final current = _currentContext;
    if (current != null) {
      final metadata = RpcContextPropagation.extractDomainMetadata(current);
      print('[$serviceName] Context: $metadata');
    }
  }

  /// Создает логгер для домена с автоматическим подхватыванием trace ID
  RpcLogger get logger => RpcLogger(serviceName);

  /// Удобный метод для логирования с автоматическим trace/request ID из контекста
  Future<void> logInfo(String message, {String? context}) async {
    await logger.info(message, context: context, rpcContext: _currentContext);
  }

  /// Удобный метод для логирования ошибок с автоматическим trace/request ID
  Future<void> logError(String message,
      {Object? error, StackTrace? stackTrace, String? context}) async {
    await logger.error(
      message,
      error: error,
      stackTrace: stackTrace,
      context: context,
      rpcContext: _currentContext,
    );
  }

  /// Удобный метод для debug логирования с автоматическим trace/request ID
  Future<void> logDebug(String message, {String? context}) async {
    await logger.internal(message,
        context: context, rpcContext: _currentContext);
  }

  /// Удобный метод для логирования предупреждений с автоматическим trace/request ID
  Future<void> logWarning(String message, {String? context}) async {
    await logger.warning(message,
        context: context, rpcContext: _currentContext);
  }
}
