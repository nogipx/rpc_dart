// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: LGPL-3.0-or-later

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';

void main() async {
  RpcLoggerSettings.setDefaultMinLogLevel(RpcLoggerLevel.internal);

  // 🔧 Настройка уровня логирования библиотеки
  // По умолчанию INFO - показывает только важные события
  // Для отладки можно установить INTERNAL - покажет все внутренние операции
  print('🔧 Уровень логирования: INFO (скрыты внутренние детали библиотеки)');

  print(
      '\n🚀 === RPC DART - Комплексная демонстрация автоматической трассировки ===\n');

  // Создаем InMemory транспорт
  final (clientTransport, serverTransport) = RpcInMemoryTransport.pair();

  // Настраиваем сервер
  final serverEndpoint = RpcResponderEndpoint(
    transport: serverTransport,
    debugLabel: 'Calculator Server',
  );
  serverEndpoint.registerServiceContract(CalculatorResponder());
  serverEndpoint.start();

  // Настраиваем клиент
  final clientEndpoint = RpcCallerEndpoint(
    transport: clientTransport,
    debugLabel: 'Calculator Client',
  );
  final calculator = CalculatorCaller(clientEndpoint);

  try {
    await Future.delayed(Duration(milliseconds: 100));

    print('📋 === 1. UNARY CALLS (один запрос → один ответ) ===\n');

    // 1. UNARY без контекста - автоматическая генерация trace ID
    print('🔹 Без контекста (автогенерация trace ID):');
    final result1 = await calculator.add(10, 20);
    print('   10 + 20 = $result1\n');

    // 2. UNARY с пользовательским контекстом
    print('🔹 С пользовательским trace ID:');
    final customContext =
        RpcContextUtils.withTracing(traceId: 'user_trace_123');
    final result2 = await calculator.multiply(5, 7, context: customContext);
    print('   5 × 7 = $result2\n');

    print('📊 === 2. SERVER STREAMING (один запрос → поток ответов) ===\n');

    print('🔹 Сложное вычисление с прогрессом:');
    await for (final progress in calculator.calculateWithProgress(
        CalculationRequest(a: 100, b: 25, operation: 'divide'))) {
      print('   📈 $progress');
    }
    print('');

    print('📥 === 3. CLIENT STREAMING (поток запросов → один ответ) ===\n');

    print('🔹 Батчевая обработка нескольких вычислений:');
    final batchRequests = Stream.fromIterable([
      CalculationRequest(a: 10, b: 5, operation: 'add'),
      CalculationRequest(a: 20, b: 4, operation: 'multiply'),
      CalculationRequest(a: 100, b: 10, operation: 'divide'),
      CalculationRequest(a: 50, b: 15, operation: 'subtract'),
      CalculationRequest(a: 7, b: 3, operation: 'add'),
    ]);

    final batchResult = await calculator.processBatch(batchRequests);
    print('   📊 $batchResult\n');

    print('🔄 === 4. BIDIRECTIONAL STREAMING (поток ↔ поток) ===\n');

    print('🔹 Интерактивные вычисления в реальном времени:');

    // Создаем поток запросов для bidirectional streaming
    final controller = StreamController<CalculationRequest>();
    final liveResults = calculator.liveCalculate(controller.stream);

    // Подписываемся на результаты
    final subscription = liveResults.listen((response) {
      if (response.success) {
        print('   ✅ Результат: ${response.result}');
      } else {
        print('   ❌ Ошибка: ${response.errorMessage}');
      }
    });

    // Отправляем запросы в реальном времени
    await Future.delayed(Duration(milliseconds: 100));
    controller.add(CalculationRequest(a: 15, b: 3, operation: 'multiply'));
    await Future.delayed(Duration(milliseconds: 200));

    controller.add(CalculationRequest(a: 100, b: 7, operation: 'divide'));
    await Future.delayed(Duration(milliseconds: 200));

    controller.add(CalculationRequest(a: 25, b: 15, operation: 'add'));
    await Future.delayed(Duration(milliseconds: 200));

    // Попробуем ошибочную операцию
    controller.add(CalculationRequest(a: 10, b: 0, operation: 'divide'));
    await Future.delayed(Duration(milliseconds: 200));

    // Закрываем поток запросов
    await controller.close();
    await subscription.asFuture();

    print('\n🎯 === ДЕМОНСТРАЦИЯ АВТОМАТИЧЕСКОЙ ТРАССИРОВКИ ===\n');

    print('✨ Trace ID автоматически:');
    print('   • Генерируется в CallerEndpoint если не указан');
    print('   • Генерируется в ResponderEndpoint если клиент не передал');
    print('   • Передается во все дочерние компоненты (Responders, Callers)');
    print('   • Появляется в логах всех операций автоматически');
    print('   • Работает через RpcLoggerFactory с контекстом');

    print('\n🔥 === ВСЕ ТИПЫ RPC ПРОДЕМОНСТРИРОВАНЫ ===');
    print('   ✅ Unary Calls - простые запрос/ответ операции');
    print('   ✅ Server Streaming - прогресс и live обновления');
    print('   ✅ Client Streaming - батчевая обработка данных');
    print('   ✅ Bidirectional Streaming - интерактивное взаимодействие');
    print('   ✅ Автоматическая трассировка во всех сценариях\n');
  } catch (e, stackTrace) {
    print('❌ Ошибка: $e');
    print('Stack trace: $stackTrace');
  } finally {
    // Закрываем ресурсы
    await serverEndpoint.close();
    await clientEndpoint.close();
    print('🔚 Демонстрация завершена!');
  }
}

/// Простая модель сообщения для демонстрации
class CalculationRequest implements IRpcSerializable {
  final double a, b;
  final String operation; // 'add', 'subtract', 'multiply', 'divide'

  CalculationRequest(
      {required this.a, required this.b, required this.operation});

  @override
  Map<String, dynamic> toJson() => {'a': a, 'b': b, 'operation': operation};

  static CalculationRequest fromJson(Map<String, dynamic> json) =>
      CalculationRequest(
        a: json['a'] is int ? (json['a'] as int).toDouble() : json['a'],
        b: json['b'] is int ? (json['b'] as int).toDouble() : json['b'],
        operation: json['operation'],
      );

  static RpcCodec<CalculationRequest> get codec =>
      RpcCodec(CalculationRequest.fromJson);

  @override
  String toString() =>
      'CalculationRequest(a: $a, b: $b, operation: $operation)';
}

class CalculationResponse implements IRpcSerializable {
  final double? result;
  final bool success;
  final String? errorMessage;

  CalculationResponse({this.result, this.success = true, this.errorMessage});

  @override
  Map<String, dynamic> toJson() => {
        'result': result,
        'success': success,
        'errorMessage': errorMessage,
      };

  static CalculationResponse fromJson(Map<String, dynamic> json) =>
      CalculationResponse(
        result: json['result'],
        success: json['success'] ?? true,
        errorMessage: json['errorMessage'],
      );

  static RpcCodec<CalculationResponse> get codec =>
      RpcCodec(CalculationResponse.fromJson);

  @override
  String toString() => success
      ? 'CalculationResponse(result: $result)'
      : 'CalculationResponse(error: $errorMessage)';
}

/// Модель для прогресса вычислений (server streaming)
class CalculationProgress implements IRpcSerializable {
  final String step;
  final double progress; // 0.0 to 1.0
  final String? currentOperation;

  CalculationProgress(
      {required this.step, required this.progress, this.currentOperation});

  @override
  Map<String, dynamic> toJson() => {
        'step': step,
        'progress': progress,
        'currentOperation': currentOperation,
      };

  static CalculationProgress fromJson(Map<String, dynamic> json) =>
      CalculationProgress(
        step: json['step'],
        progress: json['progress'],
        currentOperation: json['currentOperation'],
      );

  static RpcCodec<CalculationProgress> get codec =>
      RpcCodec(CalculationProgress.fromJson);

  @override
  String toString() =>
      'CalculationProgress(step: $step, progress: ${(progress * 100).toInt()}%)';
}

/// Модель для статистики батча (client streaming)
class BatchStatistics implements IRpcSerializable {
  final int totalRequests;
  final int successfulRequests;
  final int failedRequests;
  final double averageResult;
  final List<String> operations;

  BatchStatistics({
    required this.totalRequests,
    required this.successfulRequests,
    required this.failedRequests,
    required this.averageResult,
    required this.operations,
  });

  @override
  Map<String, dynamic> toJson() => {
        'totalRequests': totalRequests,
        'successfulRequests': successfulRequests,
        'failedRequests': failedRequests,
        'averageResult': averageResult,
        'operations': operations,
      };

  static BatchStatistics fromJson(Map<String, dynamic> json) => BatchStatistics(
        totalRequests: json['totalRequests'],
        successfulRequests: json['successfulRequests'],
        failedRequests: json['failedRequests'],
        averageResult: json['averageResult'],
        operations: List<String>.from(json['operations']),
      );

  static RpcCodec<BatchStatistics> get codec =>
      RpcCodec(BatchStatistics.fromJson);

  @override
  String toString() =>
      'BatchStatistics(total: $totalRequests, success: $successfulRequests, failed: $failedRequests, avg: $averageResult)';
}

/// Респондер с демонстрацией всех типов RPC методов
final class CalculatorResponder extends RpcResponderContract {
  CalculatorResponder() : super('CalculatorService');

  @override
  void setup() {
    // 1. UNARY CALL - один запрос → один ответ
    addUnaryMethod<CalculationRequest, CalculationResponse>(
      methodName: 'calculate',
      handler: calculate,
      requestCodec: CalculationRequest.codec,
      responseCodec: CalculationResponse.codec,
    );

    // 2. SERVER STREAMING - один запрос → поток ответов
    addServerStreamMethod<CalculationRequest, CalculationProgress>(
      methodName: 'calculateWithProgress',
      handler: calculateWithProgress,
      requestCodec: CalculationRequest.codec,
      responseCodec: CalculationProgress.codec,
    );

    // 3. CLIENT STREAMING - поток запросов → один ответ
    addClientStreamMethod<CalculationRequest, BatchStatistics>(
      methodName: 'processBatch',
      handler: processBatch,
      requestCodec: CalculationRequest.codec,
      responseCodec: BatchStatistics.codec,
    );

    // 4. BIDIRECTIONAL STREAMING - поток запросов ↔ поток ответов
    addBidirectionalMethod<CalculationRequest, CalculationResponse>(
      methodName: 'liveCalculate',
      handler: liveCalculate,
      requestCodec: CalculationRequest.codec,
      responseCodec: CalculationResponse.codec,
    );
  }

  /// UNARY: Простое вычисление
  Future<CalculationResponse> calculate(CalculationRequest request,
      {RpcContext? context}) async {
    try {
      final result = _performOperation(request.a, request.b, request.operation);
      return CalculationResponse(result: result);
    } catch (e) {
      return CalculationResponse(success: false, errorMessage: e.toString());
    }
  }

  /// SERVER STREAMING: Вычисление с отправкой прогресса
  Stream<CalculationProgress> calculateWithProgress(CalculationRequest request,
      {RpcContext? context}) async* {
    yield CalculationProgress(
        step: 'Initializing',
        progress: 0.0,
        currentOperation: request.operation);

    await Future.delayed(Duration(milliseconds: 200));
    yield CalculationProgress(
        step: 'Validating input',
        progress: 0.25,
        currentOperation: request.operation);

    await Future.delayed(Duration(milliseconds: 200));
    yield CalculationProgress(
        step: 'Performing calculation',
        progress: 0.50,
        currentOperation: request.operation);

    await Future.delayed(Duration(milliseconds: 200));
    final result = _performOperation(request.a, request.b, request.operation);
    yield CalculationProgress(
        step: 'Calculation complete',
        progress: 0.75,
        currentOperation: request.operation);

    await Future.delayed(Duration(milliseconds: 200));
    yield CalculationProgress(
        step: 'Finalizing result: $result',
        progress: 1.0,
        currentOperation: request.operation);
  }

  /// CLIENT STREAMING: Обработка батча запросов
  Future<BatchStatistics> processBatch(Stream<CalculationRequest> requests,
      {RpcContext? context}) async {
    int total = 0;
    int successful = 0;
    int failed = 0;
    double sum = 0.0;
    final operations = <String>{};

    await for (final request in requests) {
      total++;
      operations.add(request.operation);

      try {
        final result =
            _performOperation(request.a, request.b, request.operation);
        sum += result;
        successful++;
      } catch (e) {
        failed++;
      }
    }

    final averageResult = successful > 0 ? sum / successful : 0.0;

    return BatchStatistics(
      totalRequests: total,
      successfulRequests: successful,
      failedRequests: failed,
      averageResult: averageResult,
      operations: operations.toList(),
    );
  }

  /// BIDIRECTIONAL STREAMING: Интерактивные вычисления в реальном времени
  Stream<CalculationResponse> liveCalculate(Stream<CalculationRequest> requests,
      {RpcContext? context}) async* {
    await for (final request in requests) {
      try {
        final result =
            _performOperation(request.a, request.b, request.operation);
        yield CalculationResponse(result: result);
      } catch (e) {
        yield CalculationResponse(success: false, errorMessage: e.toString());
      }
    }
  }

  /// Вспомогательный метод для выполнения операций
  double _performOperation(double a, double b, String operation) {
    return switch (operation) {
      'add' => a + b,
      'subtract' => a - b,
      'multiply' => a * b,
      'divide' => b != 0 ? a / b : throw Exception('Division by zero'),
      _ => throw Exception('Unknown operation: $operation'),
    };
  }
}

/// Клиент с демонстрацией всех типов RPC вызовов
final class CalculatorCaller extends RpcCallerContract {
  CalculatorCaller(RpcCallerEndpoint endpoint)
      : super('CalculatorService', endpoint);

  /// UNARY: Простое вычисление
  Future<CalculationResponse> calculate(CalculationRequest request,
      {RpcContext? context}) {
    return callUnary<CalculationRequest, CalculationResponse>(
      methodName: 'calculate',
      requestCodec: CalculationRequest.codec,
      responseCodec: CalculationResponse.codec,
      request: request,
      context: context,
    );
  }

  /// SERVER STREAMING: Вычисление с прогрессом
  Stream<CalculationProgress> calculateWithProgress(CalculationRequest request,
      {RpcContext? context}) {
    return callServerStream<CalculationRequest, CalculationProgress>(
      methodName: 'calculateWithProgress',
      requestCodec: CalculationRequest.codec,
      responseCodec: CalculationProgress.codec,
      request: request,
      context: context,
    );
  }

  /// CLIENT STREAMING: Батчевая обработка
  Future<BatchStatistics> processBatch(Stream<CalculationRequest> requests,
      {RpcContext? context}) {
    return callClientStream<CalculationRequest, BatchStatistics>(
      methodName: 'processBatch',
      requestCodec: CalculationRequest.codec,
      responseCodec: BatchStatistics.codec,
      requests: requests,
      context: context,
    );
  }

  /// BIDIRECTIONAL STREAMING: Интерактивные вычисления
  Stream<CalculationResponse> liveCalculate(Stream<CalculationRequest> requests,
      {RpcContext? context}) {
    return callBidirectionalStream<CalculationRequest, CalculationResponse>(
      methodName: 'liveCalculate',
      requestCodec: CalculationRequest.codec,
      responseCodec: CalculationResponse.codec,
      requests: requests,
      context: context,
    );
  }

  /// Удобные методы для конкретных операций
  Future<double> add(double a, double b, {RpcContext? context}) async {
    final response = await calculate(
        CalculationRequest(a: a, b: b, operation: 'add'),
        context: context);
    if (!response.success) throw Exception(response.errorMessage);
    return response.result!;
  }

  Future<double> multiply(double a, double b, {RpcContext? context}) async {
    final response = await calculate(
        CalculationRequest(a: a, b: b, operation: 'multiply'),
        context: context);
    if (!response.success) throw Exception(response.errorMessage);
    return response.result!;
  }
}
