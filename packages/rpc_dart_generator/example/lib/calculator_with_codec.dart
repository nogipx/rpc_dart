// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// ignore_for_file: uri_has_not_been_generated

// ignore_for_file: override_on_non_overriding_member

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';

part 'calculator_with_codec.g.dart';

@RpcService(
  name: 'CalculatorSerialize',
  transferMode: RpcDataTransferMode.codec,
)
abstract class ICalculatorSerializeContract {
  @RpcMethod.unary(name: 'sum', description: 'Sum with default RpcCodec')
  Future<SumResponse> sum(SumRequest request, {RpcContext? context});
}

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
