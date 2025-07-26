// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';
import 'dart:math';

import 'package:rpc_dart_transports/rpc_dart_transports.dart';

// ============================================================================
// 📋 КОНТРАКТЫ СЕРВИСОВ
// ============================================================================

/// Пример интеграции isolate транспорта с RPC контрактами
///
/// Демонстрирует:
/// - Типобезопасные RPC контракты с isolate транспортом
/// - Преимущества isolate транспорта для CPU-intensive операций
/// - Полноценную RPC архитектуру с Responder/Caller паттерном
/// - Сравнение производительности с другими транспортами
/// Контракт для вычислительного сервиса
abstract interface class ICalculatorContract implements IRpcContract {
  static const name = 'Calculator';
  static const methodCompute = 'compute';
  static const methodBatchCompute = 'batchCompute';
  static const methodStreamCompute = 'streamCompute';

  Future<ComputeResponse> compute(ComputeRequest request);
  Future<BatchComputeResponse> batchCompute(BatchComputeRequest request);
  Stream<ComputeStepResponse> streamCompute(Stream<ComputeRequest> requests);
}

// ============================================================================
// 📦 МОДЕЛИ ДАННЫХ
// ============================================================================

/// Запрос на вычисления
class ComputeRequest {
  final String operationType;
  final List<double> numbers;
  final Map<String, dynamic> parameters;

  const ComputeRequest({
    required this.operationType,
    required this.numbers,
    this.parameters = const {},
  });

  /// Генерирует большой запрос для тестирования производительности
  factory ComputeRequest.generateLarge(int numbersCount) {
    final random = Random();
    final numbers =
        List.generate(numbersCount, (_) => random.nextDouble() * 1000);

    return ComputeRequest(
      operationType: 'complexAnalysis',
      numbers: numbers,
      parameters: {
        'iterations': 10000,
        'precision': 0.001,
        'algorithm': 'monte_carlo',
        'timestamp': DateTime.now().toIso8601String(),
      },
    );
  }
}

/// Ответ на вычисления
class ComputeResponse {
  final double result;
  final Map<String, dynamic> details;
  final Duration processingTime;
  final bool success;

  const ComputeResponse({
    required this.result,
    required this.details,
    required this.processingTime,
    required this.success,
  });
}

/// Запрос на пакетные вычисления
class BatchComputeRequest {
  final List<ComputeRequest> requests;
  final bool parallel;

  const BatchComputeRequest({
    required this.requests,
    this.parallel = true,
  });
}

/// Ответ на пакетные вычисления
class BatchComputeResponse {
  final List<ComputeResponse> results;
  final Duration totalProcessingTime;
  final int successCount;

  const BatchComputeResponse({
    required this.results,
    required this.totalProcessingTime,
    required this.successCount,
  });
}

/// Ответ на потоковые вычисления
class ComputeStepResponse {
  final String requestId;
  final double intermediateResult;
  final String step;
  final bool isComplete;

  const ComputeStepResponse({
    required this.requestId,
    required this.intermediateResult,
    required this.step,
    required this.isComplete,
  });
}

// ============================================================================
// 🎯 РЕСПОНДЕР (Серверная сторона в изоляте)
// ============================================================================

/// Респондер для вычислительного сервиса
final class CalculatorResponder extends RpcResponderContract
    implements ICalculatorContract {
  CalculatorResponder() : super(ICalculatorContract.name) {
    // Настраиваем методы
    addUnaryMethod<ComputeRequest, ComputeResponse>(
      methodName: ICalculatorContract.methodCompute,
      handler: compute,
    );

    addUnaryMethod<BatchComputeRequest, BatchComputeResponse>(
      methodName: ICalculatorContract.methodBatchCompute,
      handler: batchCompute,
    );

    addBidirectionalMethod<ComputeRequest, ComputeStepResponse>(
      methodName: ICalculatorContract.methodStreamCompute,
      handler: streamCompute,
    );
  }

  @override
  Future<ComputeResponse> compute(ComputeRequest request,
      {RpcContext? context}) async {
    final stopwatch = Stopwatch()..start();
    print(
        '🧮 [Calculator] Обработка ${request.operationType} с ${request.numbers.length} числами');

    // CPU-intensive вычисления (идеально для изолята!)
    double result = 0.0;
    final details = <String, dynamic>{};

    switch (request.operationType) {
      case 'sum':
        result = request.numbers.reduce((a, b) => a + b);
        details['operation'] = 'sum';
        break;
      case 'product':
        result = request.numbers.reduce((a, b) => a * b);
        details['operation'] = 'product';
        break;
      case 'mean':
        result =
            request.numbers.reduce((a, b) => a + b) / request.numbers.length;
        details['operation'] = 'mean';
        details['count'] = request.numbers.length;
        break;
      case 'variance':
        final mean =
            request.numbers.reduce((a, b) => a + b) / request.numbers.length;
        final squaredDiffs =
            request.numbers.map((x) => (x - mean) * (x - mean));
        result = squaredDiffs.reduce((a, b) => a + b) / request.numbers.length;
        details['operation'] = 'variance';
        details['mean'] = mean;
        break;
      case 'complexAnalysis':
        // Симулируем сложные вычисления
        final iterations = request.parameters['iterations'] as int? ?? 1000;
        double tempResult = 0.0;
        for (int i = 0; i < iterations; i++) {
          for (final number in request.numbers) {
            tempResult += sin(number * i) * cos(number / (i + 1));
          }
        }
        result = tempResult / iterations;
        details['operation'] = 'complexAnalysis';
        details['iterations'] = iterations;
        details['numbersProcessed'] = request.numbers.length;
        break;
      default:
        result = request.numbers.isEmpty ? 0.0 : request.numbers.first;
        details['operation'] = 'identity';
    }

    stopwatch.stop();
    print(
        '✅ [Calculator] Обработка завершена за ${stopwatch.elapsedMilliseconds}мс');

    return ComputeResponse(
      result: result,
      details: details,
      processingTime: stopwatch.elapsed,
      success: true,
    );
  }

  @override
  Future<BatchComputeResponse> batchCompute(BatchComputeRequest request,
      {RpcContext? context}) async {
    final stopwatch = Stopwatch()..start();
    print(
        '📊 [Calculator] Пакетная обработка ${request.requests.length} запросов');

    final results = <ComputeResponse>[];
    int successCount = 0;

    if (request.parallel) {
      // Параллельная обработка (демонстрация возможностей изолята)
      final futures = request.requests.map((req) async {
        try {
          final result = await compute(req);
          if (result.success) successCount++;
          return result;
        } catch (e) {
          print('❌ Ошибка обработки запроса: $e');
          return ComputeResponse(
            result: 0.0,
            details: {'error': e.toString()},
            processingTime: Duration.zero,
            success: false,
          );
        }
      });

      results.addAll(await Future.wait(futures));
    } else {
      // Последовательная обработка
      for (final req in request.requests) {
        try {
          final result = await compute(req);
          results.add(result);
          if (result.success) successCount++;
        } catch (e) {
          print('❌ Ошибка обработки запроса: $e');
          results.add(ComputeResponse(
            result: 0.0,
            details: {'error': e.toString()},
            processingTime: Duration.zero,
            success: false,
          ));
        }
      }
    }

    stopwatch.stop();
    print(
        '✅ [Calculator] Пакетная обработка завершена за ${stopwatch.elapsedMilliseconds}мс');

    return BatchComputeResponse(
      results: results,
      totalProcessingTime: stopwatch.elapsed,
      successCount: successCount,
    );
  }

  @override
  Stream<ComputeStepResponse> streamCompute(Stream<ComputeRequest> requests,
      {RpcContext? context}) async* {
    await for (final request in requests) {
      final requestId = 'req_${DateTime.now().millisecondsSinceEpoch}';

      // Симулируем поэтапную обработку
      final steps = ['parsing', 'validation', 'computation', 'optimization'];
      double currentResult = 0.0;

      for (int i = 0; i < steps.length; i++) {
        await Future.delayed(Duration(milliseconds: 50));

        // Промежуточные вычисления
        switch (steps[i]) {
          case 'parsing':
            currentResult = request.numbers.length.toDouble();
            break;
          case 'validation':
            currentResult =
                request.numbers.where((n) => n > 0).length.toDouble();
            break;
          case 'computation':
            currentResult = request.numbers.isEmpty
                ? 0.0
                : request.numbers.reduce((a, b) => a + b) /
                    request.numbers.length;
            break;
          case 'optimization':
            currentResult = currentResult * 1.1; // "оптимизированный" результат
            break;
        }

        final response = ComputeStepResponse(
          requestId: requestId,
          intermediateResult: currentResult,
          step: steps[i],
          isComplete: i == steps.length - 1,
        );

        yield response;
      }
    }
  }
}

// ============================================================================
// 🚀 КАЛЕР (Клиентская сторона)
// ============================================================================

/// Калер для вычислительного сервиса
final class CalculatorCaller extends RpcCallerContract
    implements ICalculatorContract {
  CalculatorCaller(RpcCallerEndpoint endpoint)
      : super(ICalculatorContract.name, endpoint);

  @override
  Future<ComputeResponse> compute(ComputeRequest request) async {
    return callUnary<ComputeRequest, ComputeResponse>(
      methodName: ICalculatorContract.methodCompute,
      request: request,
    );
  }

  @override
  Future<BatchComputeResponse> batchCompute(BatchComputeRequest request) async {
    return callUnary<BatchComputeRequest, BatchComputeResponse>(
      methodName: ICalculatorContract.methodBatchCompute,
      request: request,
    );
  }

  @override
  Stream<ComputeStepResponse> streamCompute(Stream<ComputeRequest> requests) {
    return callBidirectionalStream<ComputeRequest, ComputeStepResponse>(
      methodName: ICalculatorContract.methodStreamCompute,
      requests: requests,
    );
  }
}

// ============================================================================
// 🎯 MAIN DEMO
// ============================================================================

Future<void> main() async {
  print('🚀 RPC Dart + Isolate Transport Demo');
  print('=' * 50);

  // Создаем isolate транспорт
  final isolateResult = await RpcIsolateTransport.spawn(
    entrypoint: isolateServerEntrypoint,
    customParams: {},
    isolateId: 'calculator-demo',
    debugName: 'Calculator Demo Server',
  );

  // Настраиваем клиента
  final callerEndpoint = RpcCallerEndpoint(transport: isolateResult.transport);
  final calculator = CalculatorCaller(callerEndpoint);

  try {
    // ================================================================
    // 🧮 ПРОСТЫЕ ВЫЧИСЛЕНИЯ
    // ================================================================

    print('\n🧮 === ПРОСТЫЕ ВЫЧИСЛЕНИЯ ===');

    final simpleRequest = ComputeRequest(
      operationType: 'mean',
      numbers: [1.0, 2.0, 3.0, 4.0, 5.0],
    );

    final simpleResponse = await calculator.compute(simpleRequest);
    if (simpleResponse.success) {
      print('✅ Среднее значение: ${simpleResponse.result}');
      print('   ⏱️ Время: ${simpleResponse.processingTime.inMilliseconds}мс');
    }

    // ================================================================
    // ⚡ CPU-INTENSIVE ВЫЧИСЛЕНИЯ (Преимущество изолята!)
    // ================================================================

    print('\n⚡ === CPU-INTENSIVE ВЫЧИСЛЕНИЯ ===');

    final largeRequest = ComputeRequest.generateLarge(50000); // 50K чисел
    print('📊 Создан запрос с ${largeRequest.numbers.length} числами');

    final processingStopwatch = Stopwatch()..start();
    final complexResponse = await calculator.compute(largeRequest);
    processingStopwatch.stop();

    if (complexResponse.success) {
      print('✅ Сложные вычисления завершены!');
      print('   📊 Обработано чисел: ${largeRequest.numbers.length}');
      print('   🧮 Результат: ${complexResponse.result.toStringAsFixed(4)}');
      print(
          '   ⏱️ Время клиент-сервер: ${processingStopwatch.elapsedMilliseconds}мс');
      print(
          '   ⚙️ Время в изоляте: ${complexResponse.processingTime.inMilliseconds}мс');
    }

    // ================================================================
    // 📦 ПАКЕТНАЯ ОБРАБОТКА
    // ================================================================

    print('\n📦 === ПАКЕТНАЯ ОБРАБОТКА ===');

    final batchRequests = [
      ComputeRequest(
          operationType: 'sum',
          numbers: List.generate(1000, (i) => i.toDouble())),
      ComputeRequest(operationType: 'product', numbers: [1.1, 2.2, 3.3]),
      ComputeRequest(
          operationType: 'variance',
          numbers: List.generate(5000, (i) => (i * 0.1))),
    ];

    final batchRequest =
        BatchComputeRequest(requests: batchRequests, parallel: true);
    final batchResponse = await calculator.batchCompute(batchRequest);

    print('✅ Пакетная обработка завершена!');
    print('   📊 Обработано запросов: ${batchResponse.results.length}');
    print('   ✅ Успешных: ${batchResponse.successCount}');
    print(
        '   ⏱️ Общее время: ${batchResponse.totalProcessingTime.inMilliseconds}мс');

    for (int i = 0; i < batchResponse.results.length; i++) {
      final result = batchResponse.results[i];
      print(
          '      ${i + 1}. ${result.details['operation']}: ${result.result.toStringAsFixed(4)}');
    }

    // ================================================================
    // 🌊 BIDIRECTIONAL STREAMING (работает в isolate транспорте!)
    // ================================================================

    print('\n🌊 === BIDIRECTIONAL STREAMING ===');

    // Создаем асинхронный стрим с задержками для корректной работы
    final streamingRequests = Stream.fromIterable([
      ComputeRequest(operationType: 'mean', numbers: [10.0, 20.0, 30.0]),
      ComputeRequest(operationType: 'sum', numbers: [1.0, 2.0, 3.0, 4.0]),
      ComputeRequest(
          operationType: 'variance', numbers: [5.0, 15.0, 25.0, 35.0]),
    ]).asyncMap((request) async {
      // Небольшая задержка между запросами для корректной передачи
      await Future.delayed(Duration(milliseconds: 100));
      return request;
    });

    print('📊 Потоковая обработка нескольких запросов...');
    await for (final step in calculator.streamCompute(streamingRequests)) {
      final status = step.isComplete ? '✅' : '🔄';
      print(
          '   $status ${step.step}: ${step.intermediateResult.toStringAsFixed(2)}');
    }

    print('\n🏁 Потоковая обработка завершена!');

    // ================================================================
    // 🎯 ПРЕИМУЩЕСТВА ISOLATE ТРАНСПОРТА
    // ================================================================

    print('\n🎯 === ПРЕИМУЩЕСТВА ISOLATE ТРАНСПОРТА ===');
    print('✅ CPU-intensive операции не блокируют UI');
    print('✅ Истинный параллелизм на многоядерных системах');
    print('✅ Изоляция ошибок - краш изолята не влияет на главный поток');
    print('✅ Эффективная передача больших объектов');
    print('✅ Типобезопасные RPC контракты между изолятами');
    print('✅ Простое тестирование и отладка');
  } catch (e, stackTrace) {
    print('❌ Ошибка: $e');
    print('📍 Stack trace: $stackTrace');
  } finally {
    // Закрываем ресурсы
    await callerEndpoint.close();
    isolateResult.kill();
    print('\n🏁 Demo завершено');
  }
}

/// Entry point для сервера в изоляте
@pragma('vm:entry-point')
void isolateServerEntrypoint(
    IRpcTransport transport, Map<String, dynamic> params) {
  print('🖥️ [Isolate Server] Запущен Calculator RPC сервер');

  // Настраиваем RPC endpoint в изоляте
  final responderEndpoint = RpcResponderEndpoint(transport: transport);

  // Регистрируем вычислительный сервис
  responderEndpoint.registerServiceContract(CalculatorResponder());

  // Запускаем сервер
  responderEndpoint.start();

  print('✅ [Isolate Server] Calculator сервис готов к работе');
}
