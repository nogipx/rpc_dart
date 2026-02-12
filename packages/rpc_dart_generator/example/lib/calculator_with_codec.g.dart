// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'calculator_with_codec.dart';

// **************************************************************************
// RpcDartGenerator
// **************************************************************************

// ignore_for_file: type=lint, unused_element

class CalculatorSerializeContractNames {
  const CalculatorSerializeContractNames._();
  static const service = 'CalculatorSerialize';
  static String instance(String suffix) => '\$service\_$suffix';
  static const sum = 'sum';
}

class CalculatorSerializeContractCodecs {
  const CalculatorSerializeContractCodecs._();
  static const codecSumRequest = RpcCodec<SumRequest>.withDecoder(
    SumRequest.fromJson,
  );
  static const codecSumResponse = RpcCodec<SumResponse>.withDecoder(
    SumResponse.fromJson,
  );
}

class CalculatorSerializeContractCaller extends RpcCallerContract
    implements ICalculatorSerializeContract {
  CalculatorSerializeContractCaller(
    RpcCallerEndpoint endpoint, {
    String? serviceNameOverride,
    RpcDataTransferMode dataTransferMode = RpcDataTransferMode.codec,
  }) : super(
         serviceNameOverride ?? CalculatorSerializeContractNames.service,
         endpoint,
         dataTransferMode: dataTransferMode,
       );

  @override
  Future<SumResponse> sum(SumRequest request, {RpcContext? context}) {
    return callUnary<SumRequest, SumResponse>(
      methodName: CalculatorSerializeContractNames.sum,
      requestCodec: CalculatorSerializeContractCodecs.codecSumRequest,
      responseCodec: CalculatorSerializeContractCodecs.codecSumResponse,
      request: request,
      context: context,
    );
  }
}

abstract class CalculatorSerializeContractResponder extends RpcResponderContract
    implements ICalculatorSerializeContract {
  CalculatorSerializeContractResponder({
    String? serviceNameOverride,
    RpcDataTransferMode dataTransferMode = RpcDataTransferMode.codec,
  }) : super(
         serviceNameOverride ?? CalculatorSerializeContractNames.service,
         dataTransferMode: dataTransferMode,
       );

  @override
  void setup() {
    addUnaryMethod<SumRequest, SumResponse>(
      methodName: CalculatorSerializeContractNames.sum,
      handler: sum,
      description: 'Sum with default RpcCodec',
      requestCodec: CalculatorSerializeContractCodecs.codecSumRequest,
      responseCodec: CalculatorSerializeContractCodecs.codecSumResponse,
    );
  }
}
