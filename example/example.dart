// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: LGPL-3.0-or-later

// ignore_for_file: unused_element

import 'dart:async';
import 'dart:math';

import 'package:rpc_dart/rpc_dart.dart';

void main(List<String> args) async {
  await runCalculatorDemo();
}

/// Демонстрация использования калькулятора
Future<void> runCalculatorDemo() async {
  print('===== Запуск демонстрации калькулятора =====');

  // Создаем транспорт в памяти для демонстрации
  final transport = RpcInMemoryTransport.pair();
  RpcLoggerSettings.setDefaultMinLogLevel(RpcLoggerLevel.debug);

  // Создаем эндпоинты для клиента и сервера
  final serverEndpoint = RpcResponderEndpoint(
    transport: transport.$1,
    loggerColors: RpcLoggerColors.singleColor(AnsiColor.cyan),
  );
  final clientEndpoint = RpcCallerEndpoint(
    transport: transport.$2,
    loggerColors: RpcLoggerColors.singleColor(AnsiColor.magenta),
  );

  // Создаем сервер и регистрируем его
  final server = CalculatorResponder(simulatedDelayMs: 50);
  serverEndpoint.registerServiceContract(server);

  // Создаем клиента
  final client = CalculatorCaller(clientEndpoint);

  // Проверка типобезопасности: теперь клиентский контракт нельзя зарегистрировать
  // Раскомментируйте строку ниже, чтобы увидеть ошибку компиляции:
  // serverEndpoint.registerServiceContract(client); // ❌ Ошибка компиляции!

  // 1. Демонстрация унарного метода
  print('\n--- Унарный метод: calculate ---');
  await _demoUnaryCalculation(client);

  // 3. Демонстрация двунаправленного стрима
  print('\n--- Двунаправленный стрим: streamCalculate ---');
  await _demoBidirectionalStream(client);

  // Закрываем эндпоинты
  await serverEndpoint.close();
  await clientEndpoint.close();

  print('\n===== Демонстрация калькулятора завершена =====');
}

/// Демонстрация унарных вычислений
Future<void> _demoUnaryCalculation(CalculatorCaller client) async {
  try {
    print('DEBUG: Начало _demoUnaryCalculation');

    // Сложение
    print('DEBUG: Вызов client.add(5, 3)');
    final sum = await client.add(5, 3);
    print('5 + 3 = $sum');

    // Вычитание
    print('DEBUG: Вызов client.subtract(10, 4)');
    final diff = await client.subtract(10, 4);
    print('10 - 4 = $diff');

    // Умножение
    print('DEBUG: Вызов client.multiply(6, 7)');
    final product = await client.multiply(6, 7);
    print('6 * 7 = $product');

    // Деление
    print('DEBUG: Вызов client.divide(20, 4)');
    final quotient = await client.divide(20, 4);
    print('20 / 4 = $quotient');

    // Обработка ошибки
    try {
      print('DEBUG: Вызов client.divide(5, 0)');
      await client.divide(5, 0);
    } catch (e) {
      print('Ошибка деления на ноль: $e');
    }

    print('DEBUG: Завершение _demoUnaryCalculation');
  } catch (e) {
    print('Ошибка при выполнении унарных вычислений: $e');
    print('DEBUG: Stack trace: ${StackTrace.current}');
  }
}

/// Демонстрация двунаправленного стрима
Future<void> _demoBidirectionalStream(CalculatorCaller client) async {
  final random = Random();

  // Создаем контроллер для отправки запросов
  final requestController = StreamController<CalculationRequest>();

  final calculateStream = client.streamCalculate(requestController.stream);

  // Подписываемся на стрим ответов
  final responseSubscription = calculateStream.listen(
    (response) {
      if (response.success) {
        print('Результат: ${response.result}');
      } else {
        print('Ошибка: ${response.errorMessage}');
      }
    },
    onError: (e) => print('Ошибка стрима: $e'),
    onDone: () => print('Стрим завершен'),
  );

  // Отправляем серию случайных операций
  final operations = ['add', 'subtract', 'multiply', 'divide'];

  for (int i = 0; i < 5; i++) {
    final a = random.nextDouble() * 10;
    final b = random.nextDouble() * 5;
    final operation = operations[random.nextInt(operations.length)];

    print('Отправка: $a $operation $b');

    requestController.add(CalculationRequest(
      a: a,
      b: b,
      operation: operation,
    ));

    // Небольшая пауза между запросами
    await Future.delayed(Duration(milliseconds: 1000));
  }

  // Завершаем стрим запросов
  await requestController.close();

  // Ждем завершения всех ответов
  await responseSubscription.asFuture();
  await responseSubscription.cancel();
}

/// Общий интерфейс для контракта калькулятора
/// Определяет методы, которые должны быть реализованы
/// как на сервере, так и на клиенте
abstract interface class ICalculatorContract implements IRpcContract {
  // Имена методов
  static const methodCalculate = 'calculate';
  static const methodStreamCalculate = 'streamCalculate';

  /// Выполняет одиночную операцию
  Future<CalculationResponse> calculate(CalculationRequest request);

  /// Обрабатывает поток вычислений
  Stream<CalculationResponse> streamCalculate(
    Stream<CalculationRequest> requests,
  );
}

/// Клиентская реализация калькулятора
final class CalculatorCaller extends RpcCallerContract
    implements ICalculatorContract {
  /// Создает клиента с указанным эндпоинтом
  CalculatorCaller(RpcCallerEndpoint endpoint)
      : super('CalculatorService', endpoint);

  @override
  Future<CalculationResponse> calculate(CalculationRequest request) {
    return endpoint.unaryRequest<CalculationRequest, CalculationResponse>(
      serviceName: serviceName,
      methodName: ICalculatorContract.methodCalculate,
      requestCodec: CalculationRequest.codec,
      responseCodec: CalculationResponse.codec,
      request: request,
    );
  }

  @override
  Stream<CalculationResponse> streamCalculate(
      Stream<CalculationRequest> requests) {
    return endpoint
        .bidirectionalStream<CalculationRequest, CalculationResponse>(
      serviceName: serviceName,
      methodName: ICalculatorContract.methodStreamCalculate,
      requestCodec: CalculationRequest.codec,
      responseCodec: CalculationResponse.codec,
      requests: requests,
    );
  }

  /// Удобный метод для сложения
  Future<double> add(double a, double b) async {
    final request = CalculationRequest(a: a, b: b, operation: 'add');
    final response = await calculate(request);
    if (!response.success || response.result == null) {
      throw Exception(response.errorMessage ?? 'Failed to calculate');
    }
    return response.result!;
  }

  /// Удобный метод для вычитания
  Future<double> subtract(double a, double b) async {
    final request = CalculationRequest(a: a, b: b, operation: 'subtract');
    final response = await calculate(request);
    if (!response.success || response.result == null) {
      throw Exception(response.errorMessage ?? 'Failed to calculate');
    }
    return response.result!;
  }

  /// Удобный метод для умножения
  Future<double> multiply(double a, double b) async {
    final request = CalculationRequest(a: a, b: b, operation: 'multiply');
    final response = await calculate(request);
    if (!response.success || response.result == null) {
      throw Exception(response.errorMessage ?? 'Failed to calculate');
    }
    return response.result!;
  }

  /// Удобный метод для деления
  Future<double> divide(double a, double b) async {
    final request = CalculationRequest(a: a, b: b, operation: 'divide');
    final response = await calculate(request);
    if (!response.success || response.result == null) {
      throw Exception(response.errorMessage ?? 'Failed to calculate');
    }
    return response.result!;
  }
}

/// Серверная реализация калькулятора
final class CalculatorResponder extends RpcResponderContract
    implements ICalculatorContract {
  /// Настраиваемая задержка (мс) для имитации вычислений
  final int simulatedDelayMs;

  /// Конструктор с опциональной настройкой задержки
  CalculatorResponder({this.simulatedDelayMs = 0}) : super('CalculatorService');

  @override
  void setup() {
    // Унарный метод для простых вычислений
    addUnaryMethod<CalculationRequest, CalculationResponse>(
      methodName: ICalculatorContract.methodCalculate,
      handler: calculate,
      description: 'Выполняет одиночную операцию',
      requestCodec: CalculationRequest.codec,
      responseCodec: CalculationResponse.codec,
    );

    // Двунаправленный стрим для непрерывных вычислений
    addBidirectionalMethod<CalculationRequest, CalculationResponse>(
      methodName: ICalculatorContract.methodStreamCalculate,
      handler: streamCalculate,
      description: 'Обрабатывает поток вычислений',
      requestCodec: CalculationRequest.codec,
      responseCodec: CalculationResponse.codec,
    );
  }

  @override
  Future<CalculationResponse> calculate(CalculationRequest request) async {
    // Имитация задержки обработки на сервере
    if (simulatedDelayMs > 0) {
      await Future.delayed(Duration(milliseconds: simulatedDelayMs));
    }

    // Проверяем валидность операции
    if (!request.isValid()) {
      return CalculationResponse(
        success: false,
        errorMessage: 'Invalid operation: ${request.operation}',
      );
    }

    try {
      final result =
          _performCalculation(request.a, request.b, request.operation);
      return CalculationResponse(result: result);
    } catch (e) {
      return CalculationResponse(
        success: false,
        errorMessage: e.toString(),
      );
    }
  }

  @override
  Stream<CalculationResponse> streamCalculate(
      Stream<CalculationRequest> requests) async* {
    // Обрабатываем каждый запрос в потоке
    await for (final request in requests) {
      // Имитация задержки обработки на сервере
      if (simulatedDelayMs > 0) {
        await Future.delayed(Duration(milliseconds: simulatedDelayMs));
      }

      // Проверяем валидность операции
      if (!request.isValid()) {
        yield CalculationResponse(
          success: false,
          errorMessage: 'Invalid operation: ${request.operation}',
        );
        continue;
      }

      try {
        final result =
            _performCalculation(request.a, request.b, request.operation);
        yield CalculationResponse(result: result);
      } catch (e) {
        yield CalculationResponse(
          success: false,
          errorMessage: e.toString(),
        );
      }
    }
  }

  /// Внутренний метод для выполнения вычисления
  double _performCalculation(double a, double b, String operation) {
    switch (operation) {
      case 'add':
        return a + b;
      case 'subtract':
        return a - b;
      case 'multiply':
        return a * b;
      case 'divide':
        if (b == 0) {
          throw Exception('Division by zero');
        }
        return a / b;
      default:
        throw Exception('Unsupported operation: $operation');
    }
  }
}

/// Запрос на вычисление
class CalculationRequest implements IRpcSerializable {
  final double a;
  final double b;
  final String operation;

  CalculationRequest({
    required this.a,
    required this.b,
    required this.operation,
  });

  /// Валидация операции
  bool isValid() {
    return ['add', 'subtract', 'multiply', 'divide'].contains(operation);
  }

  @override
  Map<String, dynamic> toJson() => {
        'a': a,
        'b': b,
        'operation': operation,
      };

  static CalculationRequest fromJson(Map<String, dynamic> json) {
    return CalculationRequest(
      a: json['a'] is int ? (json['a'] as int).toDouble() : json['a'],
      b: json['b'] is int ? (json['b'] as int).toDouble() : json['b'],
      operation: json['operation'],
    );
  }

  static RpcCodec<CalculationRequest> get codec =>
      RpcCodec(CalculationRequest.fromJson);
}

/// Ответ на вычисление
class CalculationResponse implements IRpcSerializable {
  final double? result;
  final bool success;
  final String? errorMessage;

  CalculationResponse({
    this.result,
    this.success = true,
    this.errorMessage,
  });

  @override
  Map<String, dynamic> toJson() => {
        'result': result,
        'success': success,
        'errorMessage': errorMessage,
      };

  static CalculationResponse fromJson(Map<String, dynamic> json) {
    return CalculationResponse(
      result: json['result'],
      success: json['success'] ?? true,
      errorMessage: json['errorMessage'],
    );
  }

  static RpcCodec<CalculationResponse> get codec =>
      RpcCodec(CalculationResponse.fromJson);
}
