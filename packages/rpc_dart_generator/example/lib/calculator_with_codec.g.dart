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

class CalculatorCodecContractCaller extends RpcCallerContract
    implements ICalculatorCodecContract {
  CalculatorCodecContractCaller(
    RpcCallerEndpoint endpoint, {
    String? serviceNameOverride,
    RpcDataTransferMode dataTransferMode = RpcDataTransferMode.codec,
  }) : super(
         serviceNameOverride ?? CalculatorCodecContractNames.service,
         endpoint,
         dataTransferMode: dataTransferMode,
       );

  @override
  Future<SumResponse> sum(SumRequest request, {RpcContext? context}) {
    return callUnary<SumRequest, SumResponse>(
      methodName: CalculatorCodecContractNames.sum,
      requestCodec: const RpcCodec<SumRequest>.withDecoder(SumRequest.fromJson),
      responseCodec: const RpcCodec<SumResponse>.withDecoder(
        SumResponse.fromJson,
      ),
      request: request,
      context: context,
    );
  }
}

abstract class CalculatorCodecContractResponder extends RpcResponderContract
    implements ICalculatorCodecContract {
  CalculatorCodecContractResponder({
    String? serviceNameOverride,
    RpcDataTransferMode dataTransferMode = RpcDataTransferMode.codec,
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
      requestCodec: const RpcCodec<SumRequest>.withDecoder(SumRequest.fromJson),
      responseCodec: const RpcCodec<SumResponse>.withDecoder(
        SumResponse.fromJson,
      ),
    );
  }
}
