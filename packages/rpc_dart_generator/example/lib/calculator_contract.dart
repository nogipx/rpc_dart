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
