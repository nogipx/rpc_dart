// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'calculator_contract.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

SumRequest _$SumRequestFromJson(Map<String, dynamic> json) => SumRequest(
  values: (json['values'] as List<dynamic>)
      .map((e) => (e as num).toDouble())
      .toList(),
);

Map<String, dynamic> _$SumRequestToJson(SumRequest instance) =>
    <String, dynamic>{'values': instance.values};

SumResponse _$SumResponseFromJson(Map<String, dynamic> json) =>
    SumResponse(result: (json['result'] as num).toDouble());

Map<String, dynamic> _$SumResponseToJson(SumResponse instance) =>
    <String, dynamic>{'result': instance.result};

// **************************************************************************
// RpcDartGenerator
// **************************************************************************

// ignore_for_file: type=lint, unused_element

class CalculatorContractNames {
  const CalculatorContractNames._();
  static const service = 'Calculator';
  static String instance(String suffix) => '\$service\_$suffix';
  static const sum = 'sum';
  static const numbers = 'numbers';
}

final class CalculatorContractCaller extends RpcCallerContract
    implements ICalculatorContract {
  CalculatorContractCaller(
    RpcCallerEndpoint endpoint, {
    String? serviceNameOverride,
    RpcDataTransferMode dataTransferMode = RpcDataTransferMode.zeroCopy,
  }) : super(
         serviceNameOverride ?? CalculatorContractNames.service,
         endpoint,
         dataTransferMode: dataTransferMode,
       );

  @override
  Future<SumResponse> sum(SumRequest request, {RpcContext? context}) {
    return callUnary<SumRequest, SumResponse>(
      methodName: CalculatorContractNames.sum,
      request: request,
      context: context,
    );
  }

  @override
  Stream<SumResponse> numbers(SumRequest request, {RpcContext? context}) {
    return callServerStream<SumRequest, SumResponse>(
      methodName: CalculatorContractNames.numbers,
      request: request,
      context: context,
    );
  }
}

abstract class CalculatorContractResponder extends RpcResponderContract
    implements ICalculatorContract {
  CalculatorContractResponder({
    String? serviceNameOverride,
    RpcDataTransferMode dataTransferMode = RpcDataTransferMode.zeroCopy,
  }) : super(
         serviceNameOverride ?? CalculatorContractNames.service,
         dataTransferMode: dataTransferMode,
       );

  @override
  void setup() {
    addUnaryMethod<SumRequest, SumResponse>(
      methodName: CalculatorContractNames.sum,
      handler: sum,
    );
    addServerStreamMethod<SumRequest, SumResponse>(
      methodName: CalculatorContractNames.numbers,
      handler: numbers,
    );
  }
}
