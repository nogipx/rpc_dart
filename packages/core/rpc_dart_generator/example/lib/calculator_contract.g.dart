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
