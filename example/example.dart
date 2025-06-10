// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: LGPL-3.0-or-later

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';

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
  String toString() => 'CalculationRequest($a $operation $b)';
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
  String toString() => success ? 'Result: $result' : 'Error: $errorMessage';
}

/// Респондер для демонстрации автоматической трассировки
final class CalculatorResponder extends RpcResponderContract {
  CalculatorResponder() : super('CalculatorService');

  @override
  void setup() {
    addUnaryMethod<CalculationRequest, CalculationResponse>(
      methodName: 'calculate',
      handler: calculate,
      requestCodec: CalculationRequest.codec,
      responseCodec: CalculationResponse.codec,
    );

    addServerStreamMethod<CalculationRequest, CalculationResponse>(
      methodName: 'batchCalculate',
      handler: batchCalculate,
      requestCodec: CalculationRequest.codec,
      responseCodec: CalculationResponse.codec,
    );
  }

  /// Unary вычисление - демонстрирует автоматическую трассировку
  Future<CalculationResponse> calculate(CalculationRequest request,
      {RpcContext? context}) async {
    // Логгер автоматически получает trace ID из контекста через factory!
    final logger = RpcLogger('Calculator.compute', context: context);

    logger.info('Начинаем вычисление: $request');

    try {
      await Future.delayed(Duration(milliseconds: 10)); // Имитация работы

      double result;
      switch (request.operation) {
        case 'add':
          result = request.a + request.b;
        case 'subtract':
          result = request.a - request.b;
        case 'multiply':
          result = request.a * request.b;
        case 'divide':
          if (request.b == 0) throw Exception('Division by zero');
          result = request.a / request.b;
        default:
          throw Exception('Unknown operation: ${request.operation}');
      }

      logger.info('Вычисление завершено: $result');
      return CalculationResponse(result: result);
    } catch (e) {
      logger.error('Ошибка при вычислении', error: e);
      return CalculationResponse(success: false, errorMessage: e.toString());
    }
  }

  /// Server stream - демонстрирует трассировку через несколько ответов
  Stream<CalculationResponse> batchCalculate(CalculationRequest request,
      {RpcContext? context}) async* {
    final logger = RpcLogger('Calculator.batch', context: context);

    logger.info('Начинаем batch вычисление для операции: ${request.operation}');

    // Генерируем несколько результатов с разными значениями
    for (int i = 1; i <= 3; i++) {
      final modifiedRequest = CalculationRequest(
        a: request.a * i,
        b: request.b,
        operation: request.operation,
      );

      logger.info('Обрабатываем iteration $i: $modifiedRequest');

      final response = await calculate(modifiedRequest, context: context);
      yield response;

      // Небольшая задержка между результатами
      await Future.delayed(Duration(milliseconds: 50));
    }

    logger.info('Batch вычисление завершено');
  }
}

/// Клиентский caller с автоматической трассировкой
final class CalculatorCaller extends RpcCallerContract {
  CalculatorCaller(RpcCallerEndpoint endpoint)
      : super('CalculatorService', endpoint);

  /// Простое вычисление
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

  /// Batch вычисление
  Stream<CalculationResponse> batchCalculate(CalculationRequest request,
      {RpcContext? context}) {
    return callServerStream<CalculationRequest, CalculationResponse>(
      methodName: 'batchCalculate',
      requestCodec: CalculationRequest.codec,
      responseCodec: CalculationResponse.codec,
      request: request,
      context: context,
    );
  }

  /// Удобный метод для сложения
  Future<double> add(double a, double b, {RpcContext? context}) async {
    final response = await calculate(
        CalculationRequest(a: a, b: b, operation: 'add'),
        context: context);
    if (!response.success) throw Exception(response.errorMessage);
    return response.result!;
  }
}

void main() async {
  print('🚀 RPC Dart - Демонстрация автоматической трассировки\n');

  // Создаем InMemory транспорт
  final (clientTransport, serverTransport) = RpcInMemoryTransport.pair();

  // Настраиваем сервер
  final serverEndpoint = RpcResponderEndpoint(transport: serverTransport);
  serverEndpoint.registerServiceContract(CalculatorResponder());
  serverEndpoint.start();

  // Настраиваем клиент
  final clientEndpoint = RpcCallerEndpoint(transport: clientTransport);
  final calculator = CalculatorCaller(clientEndpoint);

  print('═══════════════════════════════════════════════════════════════');
  print('📌 ДЕМОНСТРАЦИЯ 1: Автоматическая генерация trace ID');
  print('═══════════════════════════════════════════════════════════════\n');

  // Обычный вызов БЕЗ контекста - trace ID создается автоматически
  print('🔸 Вызов БЕЗ контекста (автогенерация trace ID):');
  final result1 = await calculator.add(10, 20);
  print('  ✅ Результат: 10 + 20 = $result1\n');

  print('═══════════════════════════════════════════════════════════════');
  print('📌 ДЕМОНСТРАЦИЯ 2: Использование существующего trace ID');
  print('═══════════════════════════════════════════════════════════════\n');

  // Создаем контекст с custom trace ID
  final customContext = RpcContextUtils.withTracing(traceId: 'DEMO_TRACE_123');
  print('🔸 Вызов С пользовательским trace ID: ${customContext.traceId}');
  final result2 = await calculator.calculate(
    CalculationRequest(a: 15, b: 3, operation: 'multiply'),
    context: customContext,
  );
  print('  ✅ Результат: $result2\n');

  print('═══════════════════════════════════════════════════════════════');
  print('📌 ДЕМОНСТРАЦИЯ 3: Server Stream с трассировкой');
  print('═══════════════════════════════════════════════════════════════\n');

  // Вызов server stream - trace ID наследуется через все ответы
  final streamContext = RpcContextUtils.withTracing(traceId: 'BATCH_TRACE_456');
  print('🔸 Batch вычисление с trace ID: ${streamContext.traceId}');

  int responseCount = 0;
  await for (final response in calculator.batchCalculate(
    CalculationRequest(a: 5, b: 2, operation: 'add'),
    context: streamContext,
  )) {
    responseCount++;
    print('  ✅ Ответ $responseCount: $response');
  }
  print('\n');

  print('═══════════════════════════════════════════════════════════════');
  print('📌 ДЕМОНСТРАЦИЯ 4: RpcLoggerFactory с контекстом');
  print('═══════════════════════════════════════════════════════════════\n');

  // Демонстрируем как можно создать логгер с контекстом напрямую
  final demoContext = RpcContextUtils.withTracing(traceId: 'LOGGER_DEMO_789');
  print('🔸 Создаем логгер с контекстом через RpcLoggerFactory:');

  // Создаем логгер с контекстом через новый factory
  final contextLogger = RpcLogger('DemoLogger', context: demoContext);

  contextLogger.info('Этот лог автоматически содержит trace ID!');
  contextLogger.debug('Debug сообщение с автоматической трассировкой');
  contextLogger.warning('Warning с trace ID');

  // Создаем child логгер - он тоже наследует контекст!
  final childLogger = contextLogger.child('ChildModule');
  childLogger.info('Child логгер тоже автоматически имеет trace ID!');

  print('\n');

  print('═══════════════════════════════════════════════════════════════');
  print('📌 ДЕМОНСТРАЦИЯ 5: Цепочка вызовов с наследованием trace ID');
  print('═══════════════════════════════════════════════════════════════\n');

  // Создаем parent контекст
  final parentContext = RpcContextUtils.withTracing(traceId: 'CHAIN_TRACE_999');
  print('🔸 Parent context trace ID: ${parentContext.traceId}');

  // Используем parent контекст для первого вызова
  final firstResult = await calculator.calculate(
    CalculationRequest(a: 100, b: 25, operation: 'divide'),
    context: parentContext,
  );
  print('  ✅ Первый результат: $firstResult');

  // Создаем child контекст из parent'а (наследует trace ID, новый request ID)
  final childContext = parentContext.createChild();
  print('  🔗 Child context trace ID: ${childContext.traceId} (наследован)');
  print('  🔗 Child context request ID: ${childContext.requestId} (новый)');

  final secondResult = await calculator.calculate(
    CalculationRequest(a: firstResult.result!, b: 10, operation: 'add'),
    context: childContext,
  );
  print('  ✅ Второй результат: $secondResult\n');

  print('═══════════════════════════════════════════════════════════════');
  print('✨ РЕЗЮМЕ ВОЗМОЖНОСТЕЙ');
  print('═══════════════════════════════════════════════════════════════\n');

  print('🎯 CallerEndpoint:');
  print('   ✅ Автоматически создает trace ID если контекст не передан');
  print('   ✅ Использует существующий trace ID если контекст передан');
  print('   ✅ Дополняет частичный контекст trace ID\'ом\n');

  print('🎯 ResponderEndpoint:');
  print('   ✅ Автоматически создает trace ID если клиент не передал');
  print('   ✅ Использует trace ID от клиента если передан');
  print('   ✅ Все child логгеры автоматически наследуют trace ID\n');

  print('🎯 RpcLoggerFactory:');
  print('   ✅ Поддерживает создание контекстно-осведомленных логгеров');
  print('   ✅ Автоматически инжектит trace ID и request ID в логи');
  print('   ✅ Child логгеры наследуют контекст от parent\'а\n');

  print('🎯 RpcContext:');
  print('   ✅ Удобные factory методы для создания с trace ID');
  print('   ✅ Методы createChild() для наследования trace ID');
  print('   ✅ Поддержка metadata, timeout, cancellation\n');

  // Закрываем ресурсы
  await serverEndpoint.close();
  await clientEndpoint.close();

  print('🏁 Демонстрация завершена!');
}
