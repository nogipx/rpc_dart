// ignore_for_file: uri_has_not_been_generated

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_generator/rpc_dart_generator.dart';

part 'calculator_contract.g.dart';

@RpcService(name: 'Calculator', transferMode: RpcDataTransferMode.zeroCopy)
abstract class ICalculatorContract {
  @RpcMethod(name: 'sum')
  Future<SumResponse> sum(SumRequest request, {RpcContext? context});

  @RpcMethod(
    name: 'numbers',
    kind: RpcMethodKind.serverStream,
    transferMode: RpcDataTransferMode.zeroCopy,
  )
  Stream<SumResponse> numbers(SumRequest request, {RpcContext? context});
}

class SumRequest {
  SumRequest({required this.values});
  final List<double> values;
}

class SumResponse {
  SumResponse({required this.result});
  final double result;
}
