// ignore_for_file: uri_has_not_been_generated

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_generator/rpc_dart_generator.dart';

part 'calculator_with_codec.g.dart';

/// Контракт с автоматическим RpcCodec<T>.withDecoder(T.fromJson).
@RpcService(name: 'CalculatorCodec', transferMode: RpcDataTransferMode.zeroCopy)
abstract class ICalculatorCodecContract {
  @RpcMethod(name: 'sum', description: 'Sum with default RpcCodec')
  Future<SumResponse> sum(SumRequest request, {RpcContext? context});
}

class SumRequest {
  SumRequest({required this.values});

  final List<double> values;

  factory SumRequest.fromJson(Map<String, dynamic> json) {
    final raw = json['values'] as List<dynamic>? ?? const [];
    return SumRequest(values: raw.map((e) => (e as num).toDouble()).toList());
  }

  @override
  Map<String, dynamic> toJson() => {'values': values};
}

class SumResponse {
  SumResponse({required this.result});

  final double result;

  factory SumResponse.fromJson(Map<String, dynamic> json) {
    return SumResponse(result: (json['result'] as num).toDouble());
  }

  @override
  Map<String, dynamic> toJson() => {'result': result};
}
