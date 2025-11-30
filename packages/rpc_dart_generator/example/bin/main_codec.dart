import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_generator_consumer/calculator_with_codec.dart';

class CalculatorCodecResponder extends CalculatorCodecContractResponder {
  CalculatorCodecResponder() : super();

  @override
  Future<SumResponse> sum(SumRequest request, {RpcContext? context}) async {
    final total = request.values.fold<double>(0, (a, b) => a + b);
    return SumResponse(result: total);
  }
}

Future<void> main() async {
  final (callerTransport, responderTransport) = RpcInMemoryTransport.pair();

  final responderEndpoint = RpcResponderEndpoint(transport: responderTransport);
  responderEndpoint.registerServiceContract(CalculatorCodecResponder());
  responderEndpoint.start();

  final caller = CalculatorCodecContractCaller(
    RpcCallerEndpoint(transport: callerTransport),
  );

  final res = await caller.sum(SumRequest(values: [4, 5, 6]));
  print('sum with codec = ${res.result}');

  await caller.endpoint.close();
  await responderEndpoint.close();
}
