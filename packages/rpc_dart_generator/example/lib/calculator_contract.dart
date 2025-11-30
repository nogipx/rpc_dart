// ignore_for_file: uri_has_not_been_generated

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_generator/rpc_dart_generator.dart';

part 'calculator_contract.g.dart';

@RpcService(name: 'Calculator')
abstract class ICalculatorContract {
  @RpcMethod(name: 'sum')
  Future<SumResponse> sum(SumRequest request, {RpcContext? context});

  @RpcMethod(name: 'numbers', kind: RpcMethodKind.serverStream)
  Stream<SumResponse> numbers(SumRequest request, {RpcContext? context});
}

/// Быстрые ссылки на имена сервиса и методов.
typedef CalculatorNames = CalculatorContractNames;

class SumRequest implements IRpcSerializable {
  SumRequest({required this.values});

  final List<double> values;

  factory SumRequest.fromJson(Map<String, dynamic> json) {
    final raw = json['values'] as List<dynamic>? ?? const [];
    return SumRequest(values: raw.map((e) => (e as num).toDouble()).toList());
  }

  @override
  Map<String, dynamic> toJson() => {'values': values};
}

class SumResponse implements IRpcSerializable {
  SumResponse({required this.result});

  final double result;

  factory SumResponse.fromJson(Map<String, dynamic> json) {
    return SumResponse(result: (json['result'] as num).toDouble());
  }

  @override
  Map<String, dynamic> toJson() => {'result': result};
}
