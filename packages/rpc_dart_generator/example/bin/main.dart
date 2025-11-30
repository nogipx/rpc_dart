import 'package:rpc_dart/rpc_dart.dart';

import '../lib/calculator_contract.dart';

/// Concrete responder that wires generated registration to your implementation.
class CalculatorResponder extends CalculatorContractResponder {
  CalculatorResponder() : super();

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
    final total = request.values.fold<double>(0, (a, b) => a + b);
    return SumResponse(result: total);
  }
}

Future<void> main() async {
  final (callerTransport, responderTransport) = RpcInMemoryTransport.pair();

  final responderEndpoint = RpcResponderEndpoint(transport: responderTransport);
  responderEndpoint.registerServiceContract(CalculatorResponder());
  responderEndpoint.start();

  final caller = CalculatorContractCaller(
    RpcCallerEndpoint(transport: callerTransport),
  );

  final res = await caller.sum(SumRequest(values: [1, 2, 3]));
  print('sum = ${res.result}');

  await caller.endpoint.close();
  await responderEndpoint.close();
}
