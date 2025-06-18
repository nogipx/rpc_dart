// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: LGPL-3.0-or-later

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';

/// 🚀 Демонстрация всех 4 RPC паттернов с Zero-Copy
void main() async {
  print('🚀 RPC Dart - Все 4 паттерна с Zero-Copy\n');
  // RpcLogger.setDefaultMinLogLevel(RpcLoggerLevel.internal);

  // Создаем inmemory транспорт
  final (client, server) = RpcInMemoryTransport.pair();

  // Настраиваем endpoints
  final responder = RpcResponderEndpoint(transport: server);
  final caller = RpcCallerEndpoint(transport: client);

  // Регистрируем сервис
  responder.registerServiceContract(CalculatorResponder());
  responder.start();

  final calculator = CalculatorCaller(caller);

  try {
    // 1. Unary Call
    print('1️⃣ Unary: один запрос → один ответ');
    final result1 = await calculator.calculate(Request(10, 5, 'add'));
    print('   10 + 5 = ${result1.result}\n');

    // 2. Server Streaming
    print('2️⃣ Server Stream: один запрос → поток ответов');
    await for (final step
        in calculator.calculateSteps(Request(20, 4, 'multiply'))) {
      print('   📤 ${step.message}');
    }
    print('');

    // 3. Client Streaming
    print('3️⃣ Client Stream: поток запросов → один ответ');
    final requests = Stream.fromIterable([
      Request(10, 2, 'add'),
      Request(15, 3, 'multiply'),
      Request(100, 10, 'divide'),
    ]);
    final summary = await calculator.processBatch(requests);
    print('   📥 Обработано: ${summary.count}, Сумма: ${summary.total}\n');

    // 4. Bidirectional Streaming
    print('4️⃣ Bidirectional: поток запросов ↔ поток ответов');
    final controller = StreamController<Request>();
    final results = calculator.liveCalculate(controller.stream);

    // Подписываемся на результаты
    final subscription = results.listen((r) => print('   🔄 ${r.result}'));

    // Отправляем данные
    controller.add(Request(5, 3, 'multiply'));
    await Future.delayed(Duration(milliseconds: 50));
    controller.add(Request(20, 4, 'divide'));
    await Future.delayed(Duration(milliseconds: 50));

    await controller.close();
    await subscription.asFuture();

    print('\n✅ Все 4 RPC паттерна продемонстрированы!');
  } finally {
    await caller.close();
    await responder.close();
  }
}

//
// КОНТРАКТ И МОДЕЛИ
//

abstract interface class ICalculatorContract {
  static const name = 'Calculator';

  // Константы для всех методов
  static const methodCalculate = 'calculate';
  static const methodCalculateSteps = 'calculateSteps';
  static const methodProcessBatch = 'processBatch';
  static const methodLiveCalculate = 'liveCalculate';
}

// Zero-copy модели - обычные классы без кодеков
class Request {
  final double a, b;
  final String op;
  Request(this.a, this.b, this.op);
}

class Response {
  final double result;
  Response(this.result);
}

class Step {
  final String message;
  Step(this.message);
}

class Summary {
  final int count;
  final double total;
  Summary(this.count, this.total);
}

//
// СЕРВЕР (RESPONDER)
//

final class CalculatorResponder extends RpcResponderContract
    implements ICalculatorContract {
  CalculatorResponder() : super(ICalculatorContract.name);

  @override
  void setup() {
    // Zero-copy методы - кодеки НЕ указываем
    addUnaryMethod<Request, Response>(
      methodName: ICalculatorContract.methodCalculate,
      handler: calculate,
    );

    addServerStreamMethod<Request, Step>(
      methodName: ICalculatorContract.methodCalculateSteps,
      handler: calculateSteps,
    );

    addClientStreamMethod<Request, Summary>(
      methodName: ICalculatorContract.methodProcessBatch,
      handler: processBatch,
    );

    addBidirectionalMethod<Request, Response>(
      methodName: ICalculatorContract.methodLiveCalculate,
      handler: liveCalculate,
    );
  }

  // 1. Unary
  Future<Response> calculate(Request req, {RpcContext? context}) async {
    final result = _calc(req.a, req.b, req.op);
    return Response(result);
  }

  // 2. Server Streaming
  Stream<Step> calculateSteps(Request req, {RpcContext? context}) async* {
    yield Step('Начинаем: ${req.a} ${req.op} ${req.b}');
    await Future.delayed(Duration(milliseconds: 100));

    yield Step('Вычисляем...');
    await Future.delayed(Duration(milliseconds: 100));

    final result = _calc(req.a, req.b, req.op);
    yield Step('Результат: $result');
  }

  // 3. Client Streaming
  Future<Summary> processBatch(Stream<Request> reqs,
      {RpcContext? context}) async {
    int count = 0;
    double total = 0;

    await for (final req in reqs) {
      count++;
      total += _calc(req.a, req.b, req.op);
    }

    return Summary(count, total);
  }

  // 4. Bidirectional Streaming
  Stream<Response> liveCalculate(
    Stream<Request> reqs, {
    RpcContext? context,
  }) async* {
    await for (final req in reqs) {
      final result = _calc(req.a, req.b, req.op);
      yield Response(result);
    }
  }

  double _calc(double a, double b, String op) {
    return switch (op) {
      'add' => a + b,
      'multiply' => a * b,
      'divide' => a / b,
      'subtract' => a - b,
      _ => 0,
    };
  }
}

//
// КЛИЕНТ (CALLER)
//

final class CalculatorCaller extends RpcCallerContract
    implements ICalculatorContract {
  CalculatorCaller(RpcCallerEndpoint endpoint)
      : super(ICalculatorContract.name, endpoint);

  Future<Response> calculate(Request request) {
    return callUnary<Request, Response>(
      methodName: ICalculatorContract.methodCalculate,
      request: request,
    );
  }

  Stream<Step> calculateSteps(Request request) {
    return callServerStream<Request, Step>(
      methodName: ICalculatorContract.methodCalculateSteps,
      request: request,
    );
  }

  Future<Summary> processBatch(Stream<Request> requests) {
    return callClientStream<Request, Summary>(
      methodName: ICalculatorContract.methodProcessBatch,
      requests: requests,
    );
  }

  Stream<Response> liveCalculate(
    Stream<Request> requests, {
    RpcContext? context,
  }) {
    return callBidirectionalStream<Request, Response>(
      methodName: ICalculatorContract.methodLiveCalculate,
      requests: requests,
      context: context?.withTraceId('some_trace'),
    );
  }
}
