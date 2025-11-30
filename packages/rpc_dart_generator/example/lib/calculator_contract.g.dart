// GENERATED CODE - DO NOT MODIFY BY HAND
// dart format width=80

part of 'calculator_contract.dart';

// **************************************************************************
// RpcDartGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
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
    RpcDataTransferMode dataTransferMode = RpcDataTransferMode.auto,
  }) : super(
         serviceNameOverride ?? CalculatorContractNames.service,
         endpoint,
         dataTransferMode: dataTransferMode,
       );

  @override
  Future<SumResponse> sum(SumRequest request, {RpcContext? context}) {
    return callUnary<SumRequest, SumResponse>(
      methodName: CalculatorContractNames.sum,
      requestCodec: const RpcCodec<SumRequest>.withDecoder(SumRequest.fromJson),
      responseCodec: const RpcCodec<SumResponse>.withDecoder(
        SumResponse.fromJson,
      ),
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
    RpcDataTransferMode dataTransferMode = RpcDataTransferMode.auto,
  }) : super(
         serviceNameOverride ?? CalculatorContractNames.service,
         dataTransferMode: dataTransferMode,
       );

  @override
  void setup() {
    addUnaryMethod<SumRequest, SumResponse>(
      methodName: CalculatorContractNames.sum,
      handler: sum,
      requestCodec: const RpcCodec<SumRequest>.withDecoder(SumRequest.fromJson),
      responseCodec: const RpcCodec<SumResponse>.withDecoder(
        SumResponse.fromJson,
      ),
    );
    addServerStreamMethod<SumRequest, SumResponse>(
      methodName: CalculatorContractNames.numbers,
      handler: numbers,
    );
  }
}
