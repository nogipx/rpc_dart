// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_generator_consumer/calculator_contract.dart';

// V1 responder — handles Calculator/sum and Calculator/numbers.
class CalculatorV1Responder extends CalculatorContractResponder {
  @override
  Future<SumResponse> sum(SumRequest request, {RpcContext? context}) async {
    final total = request.values.fold<double>(0, (a, b) => a + b);
    return SumResponse(result: total);
  }

  @override
  Stream<SumResponse> numbers(
    SumRequest request, {
    RpcContext? context,
  }) async* {
    for (final value in request.values) {
      yield SumResponse(result: value);
    }
  }
}

// V2 responder — handles only Calculator.v2/sum.
// numbers stays on the v1 responder above.
class CalculatorV2Responder extends CalculatorContractV2Responder {
  @override
  Future<SumResponseV2> sum(SumRequest request, {RpcContext? context}) async {
    final total = request.values.fold<double>(0, (a, b) => a + b);
    return SumResponseV2(result: total, count: request.values.length);
  }
}

// V3 responder — handles only Calculator.v3/multiply.
// sum stays on v2 responder, numbers stays on v1 responder.
class CalculatorV3Responder extends CalculatorContractV3Responder {
  @override
  Future<MultiplyResponse> multiply(
    SumRequest request, {
    RpcContext? context,
  }) async {
    final product = request.values.fold<double>(1, (a, b) => a * b);
    return MultiplyResponse(result: product);
  }
}

Future<void> main() async {
  final (callerTransport, responderTransport) = RpcInMemoryTransport.pair();

  final responderEndpoint = RpcResponderEndpoint(transport: responderTransport);
  // Each responder handles its own slice of methods.
  responderEndpoint.registerServiceContract(CalculatorV1Responder());
  responderEndpoint.registerServiceContract(CalculatorV2Responder());
  responderEndpoint.registerServiceContract(CalculatorV3Responder());
  responderEndpoint.start();

  // V3 caller transparently routes across all three service versions.
  // multiply → Calculator.v3, sum → Calculator.v2, numbers → Calculator
  final caller = CalculatorContractV4Caller(
    RpcCallerEndpoint(transport: callerTransport),
  );

  final request = SumRequest(values: [1, 2, 3, 4, 5]);

  final v3 = await caller.multiply(request);
  print('v3 multiply: ${v3.result}');

  try {
    //ignore:deprecated_member_use_from_same_package
    await caller.sum(request);
  } on UnsupportedError catch (e) {
    print(e);
  }

  final numbers = await caller.numbers(request).toList();
  print('numbers: ${numbers.map((r) => r.result).toList()}');

  await caller.endpoint.close();
  await responderEndpoint.close();
}
