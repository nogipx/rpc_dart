import 'dart:async';

import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/dart/element/type.dart';
import 'package:build/build.dart';
import 'package:dart_style/dart_style.dart';
import 'package:pub_semver/pub_semver.dart';
import 'package:rpc_dart/rpc_dart.dart'
    show IRpcSerializable, RpcContext, RpcDataTransferMode;
import 'package:source_gen/source_gen.dart';

import 'annotations.dart';

final _rpcMethodChecker = const TypeChecker.typeNamed(
  RpcMethod,
  inPackage: 'rpc_dart_generator',
);
final _serializableChecker = const TypeChecker.typeNamed(
  IRpcSerializable,
  inPackage: 'rpc_dart',
);
final _contextChecker = const TypeChecker.typeNamed(
  RpcContext,
  inPackage: 'rpc_dart',
);

class RpcDartGenerator extends GeneratorForAnnotation<RpcService> {
  RpcDartGenerator();

  @override
  FutureOr<String> generateForAnnotatedElement(
    Element element,
    ConstantReader annotation,
    BuildStep buildStep,
  ) {
    if (element is! ClassElement) {
      throw InvalidGenerationSourceError(
        '@RpcService может быть применен только к классу или интерфейсу',
        element: element,
      );
    }

    final serviceMeta = _parseService(annotation);
    final baseName = _baseNameFor(element);
    final methods = _collectMethods(
      element,
      baseName,
      serviceMeta.transferMode,
    );

    _validateUniqueMethodNames(methods);

    final emitter = _Emitter(
      classElement: element,
      service: serviceMeta,
      methods: methods,
    );

    final raw = emitter.build();
    return DartFormatter(languageVersion: Version(3, 9, 0)).format(raw);
  }

  _ServiceMeta _parseService(ConstantReader reader) {
    final name = reader.peek('name')?.stringValue ?? '';
    if (name.trim().isEmpty) {
      throw InvalidGenerationSourceError(
        'Имя сервиса в @RpcService не может быть пустым',
      );
    }

    final transfer = reader.peek('transferMode')?.revive();
    final transferStr = transfer?.accessor;
    final transferMode = _transferFromAccessor(transferStr);

    return _ServiceMeta(
      name: name,
      description: reader.peek('description')?.literalValue as String?,
      transferMode: transferMode ?? RpcDataTransferMode.auto,
    );
  }

  RpcDataTransferMode? _transferFromAccessor(String? accessor) {
    if (accessor == null) return null;
    switch (accessor) {
      case 'RpcDataTransferMode.zeroCopy':
        return RpcDataTransferMode.zeroCopy;
      case 'RpcDataTransferMode.codec':
        return RpcDataTransferMode.codec;
      case 'RpcDataTransferMode.auto':
        return RpcDataTransferMode.auto;
    }
    return null;
  }

  String _baseNameFor(ClassElement element) {
    final name = element.displayName;
    if (name.length > 1 &&
        name.startsWith('I') &&
        RegExp(r'[A-Z]').hasMatch(name[1])) {
      return name.substring(1);
    }
    return name;
  }

  List<_MethodMeta> _collectMethods(
    ClassElement element,
    String baseName,
    RpcDataTransferMode serviceMode,
  ) {
    final methods = <_MethodMeta>[];
    for (final method in element.methods) {
      final rpcAnno = _rpcMethodChecker.firstAnnotationOf(method);
      if (rpcAnno == null) continue;

      final reader = ConstantReader(rpcAnno);
      final meta = _parseMethod(method, reader, baseName, serviceMode);
      methods.add(meta);
    }

    if (methods.isEmpty) {
      log.warning(
        'Класс ${element.name} помечен @RpcService, но не содержит методов с @RpcMethod',
      );
    }
    return methods;
  }

  _MethodMeta _parseMethod(
    MethodElement method,
    ConstantReader reader,
    String baseName,
    RpcDataTransferMode serviceMode,
  ) {
    final name = reader.peek('name')?.stringValue ?? '';
    if (name.trim().isEmpty) {
      throw InvalidGenerationSourceError(
        'Метод ${method.name} должен иметь непустое имя в @RpcMethod',
        element: method,
      );
    }

    final kindAccessor = reader.peek('kind')?.revive().accessor;
    final kind = _kindFromAccessor(kindAccessor) ?? RpcMethodKind.unary;

    final transferAccessor = reader.peek('transferMode')?.revive().accessor;
    final effectiveMode =
        _transferFromAccessor(transferAccessor) ?? serviceMode;

    final signature = _SignatureParser(
      method,
      kind,
      baseName,
      effectiveMode,
    ).parse();

    final requestCodecType = reader.peek('requestCodec')?.typeValue;
    final responseCodecType = reader.peek('responseCodec')?.typeValue;
    final transferMode = _transferFromAccessor(transferAccessor);

    return _MethodMeta(
      methodName: name,
      declarationName: method.displayName,
      kind: kind,
      description: reader.peek('description')?.literalValue as String?,
      signature: signature,
      requestCodecType: requestCodecType,
      responseCodecType: responseCodecType,
      transferMode: transferMode,
    );
  }

  RpcMethodKind? _kindFromAccessor(String? accessor) {
    switch (accessor) {
      case 'RpcMethodKind.unary':
        return RpcMethodKind.unary;
      case 'RpcMethodKind.serverStream':
        return RpcMethodKind.serverStream;
      case 'RpcMethodKind.clientStream':
        return RpcMethodKind.clientStream;
      case 'RpcMethodKind.bidirectionalStream':
        return RpcMethodKind.bidirectionalStream;
    }
    return null;
  }

  void _validateUniqueMethodNames(List<_MethodMeta> methods) {
    final names = <String, MethodElement>{};
    for (final method in methods) {
      final existing = names[method.methodName];
      if (existing != null) {
        throw InvalidGenerationSourceError(
          'Дублируется RPC имя метода "${method.methodName}" '
          'в ${method.declarationName} и ${existing.name}',
          element: method.signature.element,
        );
      }
      names[method.methodName] = method.signature.element;
    }
  }
}

class _Emitter {
  _Emitter({
    required this.classElement,
    required this.service,
    required this.methods,
  });

  final ClassElement classElement;
  final _ServiceMeta service;
  final List<_MethodMeta> methods;

  String get _baseName {
    final name = classElement.displayName;
    if (name.length > 1 &&
        name.startsWith('I') &&
        RegExp(r'[A-Z]').hasMatch(name[1])) {
      return name.substring(1);
    }
    return name;
  }

  String build() {
    final buffer = StringBuffer();
    buffer.writeln('// GENERATED CODE - DO NOT MODIFY BY HAND');
    buffer.writeln("// ignore_for_file: type=lint, unused_element");
    buffer.writeln();

    buffer.writeln(_buildNames());
    buffer.writeln();
    buffer.writeln(_buildCaller());
    buffer.writeln();
    buffer.writeln(_buildResponder());

    return buffer.toString();
  }

  String _buildNames() {
    final b = StringBuffer();
    final className = '${_baseName}Names';
    b.writeln('class $className {');
    b.writeln('  const $className._();');
    b.writeln("  static const service = '${service.name}';");
    b.writeln(
      r"  static String instance(String suffix) => '\$service\_$suffix';",
    );
    for (final method in methods) {
      b.writeln(
        "  static const ${method.declarationName} = '${method.methodName}';",
      );
    }
    b.writeln('}');
    return b.toString();
  }

  String _buildCaller() {
    final b = StringBuffer();
    final className = '${_baseName}Caller';
    final defaultTransfer = 'RpcDataTransferMode.${service.transferMode.name}';

    b.writeln(
      'final class $className extends RpcCallerContract '
      'implements ${classElement.name} {',
    );
    b.writeln('  $className(');
    b.writeln('    RpcCallerEndpoint endpoint, {');
    b.writeln('    String? serviceNameOverride,');
    b.writeln('    RpcDataTransferMode dataTransferMode = $defaultTransfer,');
    b.writeln('  }) : super(');
    b.writeln('          serviceNameOverride ?? ${_baseName}Names.service,');
    b.writeln('          endpoint,');
    b.writeln('          dataTransferMode: dataTransferMode,');
    b.writeln('        );');
    b.writeln();

    for (final method in methods) {
      b.writeln(
        method.signature.callerMethodImpl(method, service.transferMode),
      );
      b.writeln();
    }

    b.writeln('}');
    return b.toString();
  }

  String _buildResponder() {
    final b = StringBuffer();
    final className = '${_baseName}Responder';
    final defaultTransfer = 'RpcDataTransferMode.${service.transferMode.name}';
    b.writeln(
      'abstract class $className extends RpcResponderContract '
      'implements ${classElement.name} {',
    );
    b.writeln('  $className({');
    b.writeln('    String? serviceNameOverride,');
    b.writeln('    RpcDataTransferMode dataTransferMode = $defaultTransfer,');
    b.writeln('  }) : super(');
    b.writeln('          serviceNameOverride ?? ${_baseName}Names.service,');
    b.writeln('          dataTransferMode: dataTransferMode,');
    b.writeln('        );');
    b.writeln();
    b.writeln('  @override');
    b.writeln('  void setup() {');
    for (final method in methods) {
      b.writeln(
        '    ${method.signature.addRegistration(method, service.transferMode)};',
      );
    }
    b.writeln('  }');

    b.writeln('}');
    return b.toString();
  }
}

class _SignatureParser {
  _SignatureParser(this.element, this.kind, this.baseName, this.effectiveMode);

  final MethodElement element;
  final RpcMethodKind kind;
  final String baseName;
  final RpcDataTransferMode effectiveMode;

  _Signature parse() {
    _validateParameters();
    final parameters = element.formalParameters
        .where((p) => p.isRequiredPositional || p.isRequiredNamed)
        .toList();

    final contextParam = element.formalParameters.firstWhereOrNull(
      (p) => p.name == 'context' && p.isNamed,
    );

    if (contextParam != null &&
        !_contextChecker.isAssignableFromType(contextParam.type)) {
      throw InvalidGenerationSourceError(
        'context должен быть RpcContext?',
        element: contextParam,
      );
    }

    final requestParam = parameters.isEmpty ? null : parameters.first;

    return switch (kind) {
      RpcMethodKind.unary => _parseUnary(
          requestParam,
          contextParam,
          element.returnType,
        ),
      RpcMethodKind.serverStream => _parseServerStream(
          requestParam,
          contextParam,
          element.returnType,
        ),
      RpcMethodKind.clientStream => _parseClientStream(
          requestParam,
          contextParam,
          element.returnType,
        ),
      RpcMethodKind.bidirectionalStream => _parseBidi(
          requestParam,
          contextParam,
          element.returnType,
        ),
    };
  }

  void _validateParameters() {
    final positional = element.formalParameters
        .where((p) => p.isPositional)
        .toList(growable: false);
    final named = element.formalParameters
        .where((p) => p.isNamed)
        .toList(growable: false);

    if (positional.isEmpty) {
      throw InvalidGenerationSourceError(
        'Метод ${element.name} должен принимать хотя бы один параметр-запрос',
        element: element,
      );
    }

    if (positional.length > 1) {
      throw InvalidGenerationSourceError(
        'Метод ${element.name} должен иметь только один позиционный параметр-запрос',
        element: element,
      );
    }

    if (!positional.first.isRequiredPositional) {
      throw InvalidGenerationSourceError(
        'Параметр-запрос метода ${element.name} должен быть обязательным позиционным',
        element: positional.first,
      );
    }

    final forbiddenNamed = named.where((p) => p.name != 'context').toList();
    if (forbiddenNamed.isNotEmpty) {
      throw InvalidGenerationSourceError(
        'Метод ${element.name} поддерживает только именованный параметр context',
        element: forbiddenNamed.first,
      );
    }
  }

  _Signature _parseUnary(
    FormalParameterElement? request,
    FormalParameterElement? context,
    DartType returnType,
  ) {
    if (request == null) {
      throw InvalidGenerationSourceError(
        'Unary метод ${element.name} должен принимать запрос',
        element: element,
      );
    }

    final requestType = _expectNonStream(request.type, 'Unary запрос');
    _assertSerializable(requestType, request, effectiveMode);

    final responseType = _extractFutureGeneric(returnType);
    _assertSerializable(responseType, element, effectiveMode);

    return _Signature(
      element: element,
      baseName: baseName,
      kind: RpcMethodKind.unary,
      requestType: requestType,
      responseType: responseType,
      hasContext: context != null,
    );
  }

  _Signature _parseServerStream(
    FormalParameterElement? request,
    FormalParameterElement? context,
    DartType returnType,
  ) {
    if (request == null) {
      throw InvalidGenerationSourceError(
        'Server stream ${element.name} должен принимать запрос',
        element: element,
      );
    }
    final requestType = _expectNonStream(request.type, 'ServerStream запрос');
    _assertSerializable(requestType, request, effectiveMode);

    final responseType = _extractStreamGeneric(returnType);
    _assertSerializable(responseType, element, effectiveMode);

    return _Signature(
      element: element,
      baseName: baseName,
      kind: RpcMethodKind.serverStream,
      requestType: requestType,
      responseType: responseType,
      hasContext: context != null,
    );
  }

  _Signature _parseClientStream(
    FormalParameterElement? request,
    FormalParameterElement? context,
    DartType returnType,
  ) {
    final streamType = _expectStream(request?.type, 'ClientStream запрос');
    final innerRequest = streamType.typeArguments.first;
    _assertSerializable(innerRequest, request, effectiveMode);

    final responseType = _extractFutureGeneric(returnType);
    _assertSerializable(responseType, element, effectiveMode);

    return _Signature(
      element: element,
      baseName: baseName,
      kind: RpcMethodKind.clientStream,
      requestType: innerRequest,
      responseType: responseType,
      hasContext: context != null,
      isRequestStream: true,
    );
  }

  _Signature _parseBidi(
    FormalParameterElement? request,
    FormalParameterElement? context,
    DartType returnType,
  ) {
    final streamType = _expectStream(request?.type, 'Bidirectional запрос');
    final innerRequest = streamType.typeArguments.first;
    _assertSerializable(innerRequest, request, effectiveMode);

    final responseStream = _expectStream(returnType, 'Bidirectional ответ');
    final innerResponse = responseStream.typeArguments.first;
    _assertSerializable(innerResponse, element, effectiveMode);

    return _Signature(
      element: element,
      baseName: baseName,
      kind: RpcMethodKind.bidirectionalStream,
      requestType: innerRequest,
      responseType: innerResponse,
      hasContext: context != null,
      isRequestStream: true,
      isResponseStream: true,
    );
  }

  DartType _expectNonStream(DartType type, String context) {
    if (_isStream(type)) {
      throw InvalidGenerationSourceError(
        '$context не может быть Stream',
        element: element,
      );
    }
    return type;
  }

  InterfaceType _expectStream(DartType? type, String context) {
    if (type is InterfaceType && _isStream(type)) {
      return type;
    }
    throw InvalidGenerationSourceError(
      '$context должен быть Stream<T>',
      element: element,
    );
  }

  InterfaceType _expectFuture(DartType type, String context) {
    if (type is InterfaceType && type.isDartAsyncFuture) {
      return type;
    }
    throw InvalidGenerationSourceError(
      '$context должен возвращать Future<T>',
      element: element,
    );
  }

  DartType _extractFutureGeneric(DartType type) {
    if (type is InterfaceType && type.isDartAsyncFutureOr) {
      return type.typeArguments.first;
    }
    final future = _expectFuture(type, 'Возврат');
    return future.typeArguments.first;
  }

  DartType _extractStreamGeneric(DartType type) {
    final stream = _expectStream(type, 'Возврат');
    return stream.typeArguments.first;
  }

  void _assertSerializable(
    DartType type,
    Element? errorTarget,
    RpcDataTransferMode effectiveMode,
  ) {
    if (effectiveMode == RpcDataTransferMode.zeroCopy) {
      return;
    }
    if (_serializableChecker.isAssignableFromType(type)) return;
    if (type.isDartCoreString ||
        type.isDartCoreInt ||
        type.isDartCoreDouble ||
        type.isDartCoreBool ||
        type.getDisplayString() == 'Map<String, dynamic>') {
      return;
    }
    throw InvalidGenerationSourceError(
      'Тип ${type.getDisplayString()} '
      'не реализует IRpcSerializable',
      element: errorTarget ?? element,
    );
  }

  bool _isStream(DartType type) {
    return type.isDartAsyncStream ||
        (type is InterfaceType && type.element.name == 'Stream');
  }
}

class _Signature {
  _Signature({
    required this.element,
    required this.baseName,
    required this.kind,
    required this.requestType,
    required this.responseType,
    required this.hasContext,
    this.isRequestStream = false,
    this.isResponseStream = false,
  });

  final MethodElement element;
  final String baseName;
  final RpcMethodKind kind;
  final DartType requestType;
  final DartType responseType;
  final bool hasContext;
  final bool isRequestStream;
  final bool isResponseStream;

  String callerMethodImpl(_MethodMeta meta, RpcDataTransferMode serviceMode) {
    final buffer = StringBuffer();
    final returnType = element.returnType.getDisplayString();
    final requestTypeStr = requestType.getDisplayString();
    final responseTypeStr = responseType.getDisplayString();

    buffer.writeln('  @override');
    buffer.writeln(
      '  $returnType ${element.name}(${_buildParam(requestTypeStr)}) {',
    );
    buffer.writeln(
      '    return ${_callExpression(meta, requestTypeStr, responseTypeStr, serviceMode)};',
    );
    buffer.writeln('  }');
    return buffer.toString();
  }

  String _buildParam(String requestTypeStr) {
    final contextParam = hasContext ? ', {RpcContext? context}' : '';
    final requestVar = isRequestStream ? 'requests' : 'request';
    final requestParam = isRequestStream
        ? 'Stream<$requestTypeStr> $requestVar'
        : '$requestTypeStr $requestVar';
    return '$requestParam$contextParam';
  }

  String _callExpression(
    _MethodMeta meta,
    String requestTypeStr,
    String responseTypeStr,
    RpcDataTransferMode serviceMode,
  ) {
    final contextArg = hasContext ? ', context: context' : '';
    final requestVar = isRequestStream ? 'requests' : 'request';
    final effectiveMode = meta.transferMode ?? serviceMode;
    final useCodec = _shouldUseCodec(meta, effectiveMode);

    final requestCodec = _codecArg(
      label: 'requestCodec',
      isResponse: false,
      meta: meta,
      targetType: requestTypeStr,
      useCodec: useCodec,
    );
    final responseCodec = _codecArg(
      label: 'responseCodec',
      isResponse: true,
      meta: meta,
      targetType: responseTypeStr,
      useCodec: useCodec,
    );

    String args(String mainArg) {
      final parts = StringBuffer();
      parts.write('methodName: ${baseName}Names.${meta.declarationName}, ');
      if (requestCodec.isNotEmpty) parts.write(requestCodec);
      if (responseCodec.isNotEmpty) parts.write(responseCodec);
      parts.write(mainArg);
      if (hasContext) parts.write(contextArg);
      return parts.toString();
    }

    switch (kind) {
      case RpcMethodKind.unary:
        return 'callUnary<$requestTypeStr, $responseTypeStr>('
            "${args('request: $requestVar')})";
      case RpcMethodKind.serverStream:
        return 'callServerStream<$requestTypeStr, $responseTypeStr>('
            "${args('request: $requestVar')})";
      case RpcMethodKind.clientStream:
        return 'callClientStream<$requestTypeStr, $responseTypeStr>('
            "${args('requests: $requestVar')})";
      case RpcMethodKind.bidirectionalStream:
        return 'callBidirectionalStream<$requestTypeStr, $responseTypeStr>('
            "${args('requests: $requestVar')})";
    }
  }

  String addRegistration(_MethodMeta meta, RpcDataTransferMode serviceMode) {
    final requestTypeStr = requestType.getDisplayString();
    final responseTypeStr = responseType.getDisplayString();
    final description = meta.description == null
        ? ''
        : "description: '${_escape(meta.description!)}', ";

    final effectiveMode = meta.transferMode ?? serviceMode;
    final useCodec = _shouldUseCodec(meta, effectiveMode);

    final requestCodec = _codecString(
      isResponse: false,
      useDefault: useCodec,
      providedCodecType: meta.requestCodecType,
      targetType: requestTypeStr,
    );
    final responseCodec = _codecString(
      isResponse: true,
      useDefault: useCodec,
      providedCodecType: meta.responseCodecType,
      targetType: responseTypeStr,
    );

    switch (kind) {
      case RpcMethodKind.unary:
        return "addUnaryMethod<$requestTypeStr, $responseTypeStr>(methodName: ${baseName}Names.${meta.declarationName}, handler: ${meta.declarationName}, $description$requestCodec$responseCodec)";
      case RpcMethodKind.serverStream:
        return "addServerStreamMethod<$requestTypeStr, $responseTypeStr>(methodName: ${baseName}Names.${meta.declarationName}, handler: ${meta.declarationName}, $description$requestCodec$responseCodec)";
      case RpcMethodKind.clientStream:
        return "addClientStreamMethod<$requestTypeStr, $responseTypeStr>(methodName: ${baseName}Names.${meta.declarationName}, handler: ${meta.declarationName}, $description$requestCodec$responseCodec)";
      case RpcMethodKind.bidirectionalStream:
        return "addBidirectionalStreamMethod<$requestTypeStr, $responseTypeStr>(methodName: ${baseName}Names.${meta.declarationName}, handler: ${meta.declarationName}, $description$requestCodec$responseCodec)";
    }
  }

  bool _shouldUseCodec(_MethodMeta meta, RpcDataTransferMode effectiveMode) {
    if (effectiveMode == RpcDataTransferMode.zeroCopy) return false;
    if (meta.requestCodecType != null || meta.responseCodecType != null) {
      return true;
    }
    // transferMode auto/codec → подставляем дефолтный RpcCodec
    return true;
  }

  String _codecString({
    required bool isResponse,
    required bool useDefault,
    required DartType? providedCodecType,
    required String targetType,
  }) {
    final label = isResponse ? 'responseCodec' : 'requestCodec';
    if (!useDefault) return '';
    if (providedCodecType != null) {
      return '$label: const ${providedCodecType.getDisplayString()}(), ';
    }
    return '$label: const RpcCodec<$targetType>.withDecoder($targetType.fromJson), ';
  }

  String _codecArg({
    required String label,
    required bool isResponse,
    required _MethodMeta meta,
    required String targetType,
    required bool useCodec,
  }) {
    if (!useCodec) return '';
    final codecType =
        isResponse ? meta.responseCodecType : meta.requestCodecType;
    if (codecType != null) {
      return '$label: const ${codecType.getDisplayString()}(), ';
    }
    return '$label: const RpcCodec<$targetType>.withDecoder($targetType.fromJson), ';
  }

  String _escape(String value) => value.replaceAll("'", "\\'");
}

class _ServiceMeta {
  _ServiceMeta({
    required this.name,
    required this.transferMode,
    this.description,
  });

  final String name;
  final RpcDataTransferMode transferMode;
  final String? description;
}

class _MethodMeta {
  _MethodMeta({
    required this.methodName,
    required this.declarationName,
    required this.kind,
    required this.signature,
    this.description,
    this.requestCodecType,
    this.responseCodecType,
    this.transferMode,
  });

  final String methodName;
  final String declarationName;
  final RpcMethodKind kind;
  final _Signature signature;
  final String? description;
  final DartType? requestCodecType;
  final DartType? responseCodecType;
  final RpcDataTransferMode? transferMode;
}

extension<E> on Iterable<E> {
  E? firstWhereOrNull(bool Function(E element) test) {
    for (final e in this) {
      if (test(e)) return e;
    }
    return null;
  }
}
