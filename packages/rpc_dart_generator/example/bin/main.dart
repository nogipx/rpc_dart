// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'package:rpc_dart/rpc_dart.dart';

import 'package:rpc_dart_generator_consumer/calculator_contract.dart';

/// Concrete responder that wires generated registration to your implementation.
class CalculatorResponder extends CalculatorContractResponder {
  CalculatorResponder({String? serviceName})
    : super(serviceNameOverride: serviceName);

  @override
  Stream<SumResponse> numbers(
    SumRequest request, {
    RpcContext? context,
  }) async* {
    for (final value in request.values) {
      yield SumResponse(result: value);
    }
  }

  @override
  Future<SumResponse> sum(SumRequest request, {RpcContext? context}) async {
    if (serviceName == CalculatorContractNames.instance('beta')) {
      return SumResponse(result: 1);
    }
    final total = request.values.fold<double>(0, (a, b) => a + b);
    return SumResponse(result: total);
  }
}

Future<void> main() async {
  final (callerTransport, responderTransport) = RpcInMemoryTransport.pair();

  final responderEndpoint = RpcResponderEndpoint(transport: responderTransport);
  responderEndpoint.registerServiceContract(CalculatorResponder());
  responderEndpoint.registerServiceContract(
    CalculatorResponder(serviceName: CalculatorContractNames.instance('beta')),
  );
  responderEndpoint.start();

  final caller = CalculatorContractCaller(
    RpcCallerEndpoint(transport: callerTransport),
  );

  final res = await caller.sum(SumRequest(values: [1, 2, 3]));
  print('sum = ${res.result}');

  await caller.endpoint.close();
  await responderEndpoint.close();
}
