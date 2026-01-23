// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'calculator_with_codec.dart';

// **************************************************************************
// RpcDartGenerator
// **************************************************************************

// ignore_for_file: type=lint, unused_element

class CalculatorCodecContractNames {
  const CalculatorCodecContractNames._();
  static const service = 'CalculatorCodec';
  static String instance(String suffix) => '\$service\_$suffix';
  static const sum = 'sum';
}

final class CalculatorCodecContractCaller extends RpcCallerContract
    implements ICalculatorCodecContract {
  CalculatorCodecContractCaller(
    RpcCallerEndpoint endpoint, {
    String? serviceNameOverride,
    RpcDataTransferMode dataTransferMode = RpcDataTransferMode.zeroCopy,
  }) : super(
         serviceNameOverride ?? CalculatorCodecContractNames.service,
         endpoint,
         dataTransferMode: dataTransferMode,
       );

  @override
  Future<SumResponse> sum(SumRequest request, {RpcContext? context}) {
    return callUnary<SumRequest, SumResponse>(
      methodName: CalculatorCodecContractNames.sum,
      request: request,
      context: context,
    );
  }
}

abstract class CalculatorCodecContractResponder extends RpcResponderContract
    implements ICalculatorCodecContract {
  CalculatorCodecContractResponder({
    String? serviceNameOverride,
    RpcDataTransferMode dataTransferMode = RpcDataTransferMode.zeroCopy,
  }) : super(
         serviceNameOverride ?? CalculatorCodecContractNames.service,
         dataTransferMode: dataTransferMode,
       );

  @override
  void setup() {
    addUnaryMethod<SumRequest, SumResponse>(
      methodName: CalculatorCodecContractNames.sum,
      handler: sum,
      description: 'Sum with default RpcCodec',
    );
  }
}
