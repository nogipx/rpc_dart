// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// ignore_for_file: uri_has_not_been_generated

import 'dart:async';

import 'package:json_annotation/json_annotation.dart';
import 'package:rpc_dart/rpc_dart.dart';

part 'calculator_contract.g.dart';

@RpcService(name: 'Calculator', transferMode: RpcDataTransferMode.zeroCopy)
abstract class ICalculatorContract {
  @RpcMethod.unary(name: 'sum')
  Future<SumResponse> sum(SumRequest request, {RpcContext? context});

  @RpcMethod(
    name: 'numbers',
    kind: RpcMethodKind.serverStream,
    transferMode: RpcDataTransferMode.zeroCopy,
  )
  Stream<SumResponse> numbers(SumRequest request, {RpcContext? context});
}

/// V2 overrides [sum] to return richer [SumResponseV2] (adds [count]).
/// [numbers] is inherited unchanged from [ICalculatorContract].
@RpcService(name: 'Calculator.v2', transferMode: RpcDataTransferMode.zeroCopy)
abstract class ICalculatorContractV2 implements ICalculatorContract {
  @override
  @RpcMethod.unary(name: 'sum')
  Future<SumResponseV2> sum(SumRequest request, {RpcContext? context});
}

/// V3 adds [multiply]. Inherits [sum] from v2 and [numbers] from v1.
@RpcService(name: 'Calculator.v3', transferMode: RpcDataTransferMode.zeroCopy)
abstract class ICalculatorContractV3 implements ICalculatorContractV2 {
  @RpcMethod.unary(name: 'multiply')
  Future<MultiplyResponse> multiply(SumRequest request, {RpcContext? context});
}

/// V4 removes [sum] — clients should use [multiply] instead.
/// [numbers] and [multiply] are inherited unchanged.
@RpcService(name: 'Calculator.v4', transferMode: RpcDataTransferMode.zeroCopy)
abstract class ICalculatorContractV4 implements ICalculatorContractV3 {
  @RpcRemoved('sum has been removed. Use multiply() instead.')
  @override
  Future<SumResponseV2> sum(SumRequest request, {RpcContext? context});
}

@JsonSerializable()
class SumRequest {
  SumRequest({required this.values});
  final List<double> values;

  factory SumRequest.fromJson(Map<String, dynamic> json) =>
      _$SumRequestFromJson(json);

  Map<String, dynamic> toJson() => _$SumRequestToJson(this);
}

@JsonSerializable()
class SumResponse {
  SumResponse({required this.result});
  final double result;

  factory SumResponse.fromJson(Map<String, dynamic> json) =>
      _$SumResponseFromJson(json);

  Map<String, dynamic> toJson() => _$SumResponseToJson(this);
}

@JsonSerializable()
class MultiplyResponse {
  MultiplyResponse({required this.result});
  final double result;

  factory MultiplyResponse.fromJson(Map<String, dynamic> json) =>
      _$MultiplyResponseFromJson(json);

  Map<String, dynamic> toJson() => _$MultiplyResponseToJson(this);
}

/// V2 response: extends [SumResponse] with [count] — number of values summed.
@JsonSerializable()
class SumResponseV2 extends SumResponse {
  SumResponseV2({required super.result, required this.count});
  final int count;

  factory SumResponseV2.fromJson(Map<String, dynamic> json) =>
      _$SumResponseV2FromJson(json);

  @override
  Map<String, dynamic> toJson() => _$SumResponseV2ToJson(this);
}
