// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'calculator_with_codec.dart';

// **************************************************************************
// RpcDartGenerator
// **************************************************************************

// ignore_for_file: type=lint, unused_element

class CalculatorSerializeContractNames {
  const CalculatorSerializeContractNames._();
  static const service = 'CalculatorSerialize';
  static String instance(String suffix) => '$service\_$suffix';
  static const sum = 'sum';

  /// FileDescriptorProto bytes for gRPC Server Reflection.
  /// Register with: registry.addFileDescriptor(CalculatorSerializeContractNames.grpcDescriptor)
  static final grpcDescriptor = Uint8List.fromList(const [
    10,
    25,
    67,
    97,
    108,
    99,
    117,
    108,
    97,
    116,
    111,
    114,
    83,
    101,
    114,
    105,
    97,
    108,
    105,
    122,
    101,
    46,
    112,
    114,
    111,
    116,
    111,
    34,
    36,
    10,
    10,
    83,
    117,
    109,
    82,
    101,
    113,
    117,
    101,
    115,
    116,
    18,
    22,
    10,
    6,
    118,
    97,
    108,
    117,
    101,
    115,
    24,
    1,
    32,
    3,
    40,
    1,
    82,
    6,
    118,
    97,
    108,
    117,
    101,
    115,
    34,
    37,
    10,
    11,
    83,
    117,
    109,
    82,
    101,
    115,
    112,
    111,
    110,
    115,
    101,
    18,
    22,
    10,
    6,
    114,
    101,
    115,
    117,
    108,
    116,
    24,
    1,
    32,
    1,
    40,
    1,
    82,
    6,
    114,
    101,
    115,
    117,
    108,
    116,
    50,
    55,
    10,
    19,
    67,
    97,
    108,
    99,
    117,
    108,
    97,
    116,
    111,
    114,
    83,
    101,
    114,
    105,
    97,
    108,
    105,
    122,
    101,
    18,
    32,
    10,
    3,
    115,
    117,
    109,
    18,
    11,
    46,
    83,
    117,
    109,
    82,
    101,
    113,
    117,
    101,
    115,
    116,
    26,
    12,
    46,
    83,
    117,
    109,
    82,
    101,
    115,
    112,
    111,
    110,
    115,
    101,
  ]);
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
