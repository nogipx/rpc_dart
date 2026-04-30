// Quick smoke test: verify generated grpcDescriptor is parseable.
import '../lib/calculator_contract.dart';
import 'package:rpc_dart_grpc_reflection/rpc_dart_grpc_reflection.dart';

void main() {
  final registry = RpcReflectionRegistry()
    ..addFileDescriptor(CalculatorContractNames.grpcDescriptor)
    ..addFileDescriptor(CalculatorContractV2Names.grpcDescriptor)
    ..addFileDescriptor(CalculatorContractV3Names.grpcDescriptor);

  print('Services: ${registry.serviceNames}');

  for (final svc in registry.serviceNames) {
    final bytes = registry.fileContainingSymbol(svc);
    print('  $svc → ${bytes != null ? '${bytes.length} bytes' : 'no descriptor'}');
  }
}
