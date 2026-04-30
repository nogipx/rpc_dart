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

MultiplyResponse _$MultiplyResponseFromJson(Map<String, dynamic> json) =>
    MultiplyResponse(result: (json['result'] as num).toDouble());

Map<String, dynamic> _$MultiplyResponseToJson(MultiplyResponse instance) =>
    <String, dynamic>{'result': instance.result};

SumResponseV2 _$SumResponseV2FromJson(Map<String, dynamic> json) =>
    SumResponseV2(
      result: (json['result'] as num).toDouble(),
      count: (json['count'] as num).toInt(),
    );

Map<String, dynamic> _$SumResponseV2ToJson(SumResponseV2 instance) =>
    <String, dynamic>{'result': instance.result, 'count': instance.count};

// **************************************************************************
// RpcDartGenerator
// **************************************************************************

// ignore_for_file: type=lint, unused_element

class CalculatorContractNames {
  const CalculatorContractNames._();
  static const service = 'Calculator';
  static String instance(String suffix) => '$service\_$suffix';
  static const sum = 'sum';
  static const numbers = 'numbers';

  /// FileDescriptorProto bytes for gRPC Server Reflection.
  /// Register with: registry.addFileDescriptor(CalculatorContractNames.grpcDescriptor)
  static final grpcDescriptor = Uint8List.fromList(const [
    10,
    16,
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
    84,
    10,
    10,
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
    18,
    36,
    10,
    7,
    110,
    117,
    109,
    98,
    101,
    114,
    115,
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

class CalculatorContractCaller extends RpcCallerContract
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

// ignore_for_file: type=lint, unused_element

class CalculatorContractV2Names {
  const CalculatorContractV2Names._();
  static const service = 'Calculator.v2';
  static String instance(String suffix) => '$service\_$suffix';
  static const sum = 'sum';

  /// FileDescriptorProto bytes for gRPC Server Reflection.
  /// Register with: registry.addFileDescriptor(CalculatorContractV2Names.grpcDescriptor)
  static final grpcDescriptor = Uint8List.fromList(const [
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
    95,
    118,
    50,
    46,
    112,
    114,
    111,
    116,
    111,
    18,
    10,
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
    13,
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
    86,
    50,
    18,
    20,
    10,
    5,
    99,
    111,
    117,
    110,
    116,
    24,
    1,
    32,
    1,
    40,
    5,
    82,
    5,
    99,
    111,
    117,
    110,
    116,
    50,
    62,
    10,
    2,
    118,
    50,
    18,
    56,
    10,
    3,
    115,
    117,
    109,
    18,
    22,
    46,
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
    25,
    46,
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
    86,
    50,
  ]);
}

class CalculatorContractV2Caller extends RpcCallerContract
    implements ICalculatorContractV2 {
  final CalculatorContractCaller _parent;

  CalculatorContractV2Caller(
    RpcCallerEndpoint endpoint, {
    String? serviceNameOverride,
    RpcDataTransferMode dataTransferMode = RpcDataTransferMode.zeroCopy,
  }) : _parent = CalculatorContractCaller(
         endpoint,
         dataTransferMode: dataTransferMode,
       ),
       super(
         serviceNameOverride ?? CalculatorContractV2Names.service,
         endpoint,
         dataTransferMode: dataTransferMode,
       );

  @override
  Future<SumResponseV2> sum(SumRequest request, {RpcContext? context}) {
    return callUnary<SumRequest, SumResponseV2>(
      methodName: CalculatorContractV2Names.sum,
      request: request,
      context: context,
    );
  }

  @override
  Stream<SumResponse> numbers(SumRequest request, {RpcContext? context}) {
    return _parent.numbers(request, context: context);
  }
}

abstract class CalculatorContractV2Responder extends RpcResponderContract {
  CalculatorContractV2Responder({
    String? serviceNameOverride,
    RpcDataTransferMode dataTransferMode = RpcDataTransferMode.zeroCopy,
  }) : super(
         serviceNameOverride ?? CalculatorContractV2Names.service,
         dataTransferMode: dataTransferMode,
       );

  @override
  void setup() {
    addUnaryMethod<SumRequest, SumResponseV2>(
      methodName: CalculatorContractV2Names.sum,
      handler: sum,
    );
  }

  Future<SumResponseV2> sum(SumRequest request, {RpcContext? context});
}

// ignore_for_file: type=lint, unused_element

class CalculatorContractV3Names {
  const CalculatorContractV3Names._();
  static const service = 'Calculator.v3';
  static String instance(String suffix) => '$service\_$suffix';
  static const multiply = 'multiply';

  /// FileDescriptorProto bytes for gRPC Server Reflection.
  /// Register with: registry.addFileDescriptor(CalculatorContractV3Names.grpcDescriptor)
  static final grpcDescriptor = Uint8List.fromList(const [
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
    95,
    118,
    51,
    46,
    112,
    114,
    111,
    116,
    111,
    18,
    10,
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
    42,
    10,
    16,
    77,
    117,
    108,
    116,
    105,
    112,
    108,
    121,
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
    70,
    10,
    2,
    118,
    51,
    18,
    64,
    10,
    8,
    109,
    117,
    108,
    116,
    105,
    112,
    108,
    121,
    18,
    22,
    46,
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
    28,
    46,
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
    46,
    77,
    117,
    108,
    116,
    105,
    112,
    108,
    121,
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

class CalculatorContractV3Caller extends RpcCallerContract
    implements ICalculatorContractV3 {
  final CalculatorContractV2Caller _parent;

  CalculatorContractV3Caller(
    RpcCallerEndpoint endpoint, {
    String? serviceNameOverride,
    RpcDataTransferMode dataTransferMode = RpcDataTransferMode.zeroCopy,
  }) : _parent = CalculatorContractV2Caller(
         endpoint,
         dataTransferMode: dataTransferMode,
       ),
       super(
         serviceNameOverride ?? CalculatorContractV3Names.service,
         endpoint,
         dataTransferMode: dataTransferMode,
       );

  @override
  Future<MultiplyResponse> multiply(SumRequest request, {RpcContext? context}) {
    return callUnary<SumRequest, MultiplyResponse>(
      methodName: CalculatorContractV3Names.multiply,
      request: request,
      context: context,
    );
  }

  @override
  Future<SumResponseV2> sum(SumRequest request, {RpcContext? context}) {
    return _parent.sum(request, context: context);
  }

  @override
  Stream<SumResponse> numbers(SumRequest request, {RpcContext? context}) {
    return _parent.numbers(request, context: context);
  }
}

abstract class CalculatorContractV3Responder extends RpcResponderContract {
  CalculatorContractV3Responder({
    String? serviceNameOverride,
    RpcDataTransferMode dataTransferMode = RpcDataTransferMode.zeroCopy,
  }) : super(
         serviceNameOverride ?? CalculatorContractV3Names.service,
         dataTransferMode: dataTransferMode,
       );

  @override
  void setup() {
    addUnaryMethod<SumRequest, MultiplyResponse>(
      methodName: CalculatorContractV3Names.multiply,
      handler: multiply,
    );
  }

  Future<MultiplyResponse> multiply(SumRequest request, {RpcContext? context});
}

// ignore_for_file: type=lint, unused_element

class CalculatorContractV4Names {
  const CalculatorContractV4Names._();
  static const service = 'Calculator.v4';
  static String instance(String suffix) => '$service\_$suffix';
}

class CalculatorContractV4Caller extends RpcCallerContract
    implements ICalculatorContractV4 {
  final CalculatorContractV3Caller _parent;

  CalculatorContractV4Caller(
    RpcCallerEndpoint endpoint, {
    String? serviceNameOverride,
    RpcDataTransferMode dataTransferMode = RpcDataTransferMode.zeroCopy,
  }) : _parent = CalculatorContractV3Caller(
         endpoint,
         dataTransferMode: dataTransferMode,
       ),
       super(
         serviceNameOverride ?? CalculatorContractV4Names.service,
         endpoint,
         dataTransferMode: dataTransferMode,
       );

  @override
  Future<MultiplyResponse> multiply(SumRequest request, {RpcContext? context}) {
    return _parent.multiply(request, context: context);
  }

  @override
  Stream<SumResponse> numbers(SumRequest request, {RpcContext? context}) {
    return _parent.numbers(request, context: context);
  }

  @Deprecated('sum has been removed. Use multiply() instead.')
  @override
  Future<SumResponseV2> sum(SumRequest request, {RpcContext? context}) =>
      throw UnsupportedError('sum has been removed. Use multiply() instead.');
}

abstract class CalculatorContractV4Responder extends RpcResponderContract {
  CalculatorContractV4Responder({
    String? serviceNameOverride,
    RpcDataTransferMode dataTransferMode = RpcDataTransferMode.zeroCopy,
  }) : super(
         serviceNameOverride ?? CalculatorContractV4Names.service,
         dataTransferMode: dataTransferMode,
       );

  @override
  void setup() {}
}
