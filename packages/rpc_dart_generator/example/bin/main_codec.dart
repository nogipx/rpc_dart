// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_generator_consumer/calculator_with_codec.dart';

class CalculatorSerializeResponder
    extends CalculatorSerializeContractResponder {
  CalculatorSerializeResponder()
    : super(dataTransferMode: RpcDataTransferMode.codec);

  @override
  Future<SumResponse> sum(SumRequest request, {RpcContext? context}) async {
    final total = request.values.fold<double>(0, (a, b) => a + b);
    return SumResponse(result: total);
  }
}

Future<void> main() async {
  RpcLogger.setDefaultMinLogLevel(RpcLoggerLevel.internal);
  final (callerTransport, responderTransport) = RpcInMemoryTransport.pair();

  final responderEndpoint = RpcResponderEndpoint(transport: responderTransport);
  responderEndpoint.registerServiceContract(CalculatorSerializeResponder());
  responderEndpoint.start();

  final caller = CalculatorSerializeContractCaller(
    RpcCallerEndpoint(transport: callerTransport),
    dataTransferMode: RpcDataTransferMode.codec,
  );

  final res = await caller.sum(SumRequest(values: [4, 5, 6]));
  print('sum with codec = ${res.result}');

  await caller.endpoint.close();
  await responderEndpoint.close();
}
