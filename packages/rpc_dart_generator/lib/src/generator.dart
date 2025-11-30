import 'dart:async';

import 'package:analyzer/dart/constant/value.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/dart/element/type.dart';
import 'package:build/build.dart';
import 'package:dart_style/dart_style.dart';
import 'package:pub_semver/pub_semver.dart';
import 'package:rpc_dart/rpc_dart.dart'
    show IRpcSerializable, RpcContext, RpcDataTransferMode;
import 'package:source_gen/source_gen.dart';

import 'annotations.dart';

final _rpcServiceChecker = const TypeChecker.typeNamed(
  RpcService,
  inPackage: 'rpc_dart_generator',
);
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
    final methods = _collectMethods(element);

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
    final transferStr = transfer == null ? null : transfer.accessor;
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

  List<_MethodMeta> _collectMethods(ClassElement element) {
    final methods = <_MethodMeta>[];
    for (final method in element.methods) {
      final rpcAnno = _rpcMethodChecker.firstAnnotationOf(method);
      if (rpcAnno == null) continue;

      final reader = ConstantReader(rpcAnno);
      final meta = _parseMethod(method, reader);
      methods.add(meta);
    }

    if (methods.isEmpty) {
      log.warning(
        'Класс ${element.name} помечен @RpcService, но не содержит методов с @RpcMethod',
      );
    }
    return methods;
  }

  _MethodMeta _parseMethod(MethodElement method, ConstantReader reader) {
    final name = reader.peek('name')?.stringValue ?? '';
    if (name.trim().isEmpty) {
      throw InvalidGenerationSourceError(
        'Метод ${method.name} должен иметь непустое имя в @RpcMethod',
        element: method,
      );
    }

    final kindAccessor = reader.peek('kind')?.revive().accessor;
    final kind = _kindFromAccessor(kindAccessor) ?? RpcMethodKind.unary;

    final signature = _SignatureParser(method, kind).parse();

    final requestCodecType = reader.peek('requestCodec')?.typeValue;
    final responseCodecType = reader.peek('responseCodec')?.typeValue;

    return _MethodMeta(
      methodName: name,
      declarationName: method.displayName,
      kind: kind,
      description: reader.peek('description')?.literalValue as String?,
      signature: signature,
      requestCodecType: requestCodecType,
      responseCodecType: responseCodecType,
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

  String build() {
    final buffer = StringBuffer();
    buffer.writeln('// GENERATED CODE - DO NOT MODIFY BY HAND');
    buffer.writeln("// ignore_for_file: type=lint, unused_element");
    buffer.writeln();

    buffer.writeln(_buildCaller());
    buffer.writeln();
    buffer.writeln(_buildResponder());

    return buffer.toString();
  }

  String _buildCaller() {
    final b = StringBuffer();
    final className = '${classElement.name}Caller';
    final defaultTransfer = 'RpcDataTransferMode.${service.transferMode.name}';

    b.writeln(
      'class $className extends RpcCallerContract '
      'implements ${classElement.name} {',
    );
    b.writeln('  $className(');
    b.writeln('    RpcCallerEndpoint endpoint, {');
    b.writeln('    RpcDataTransferMode dataTransferMode = $defaultTransfer,');
    b.writeln('  }) : super(');
    b.writeln("          '${service.name}',");
    b.writeln('          endpoint,');
    b.writeln('          dataTransferMode: dataTransferMode,');
    b.writeln('        );');
    b.writeln();

    for (final method in methods) {
      b.writeln(method.signature.callerMethodImpl(method));
      b.writeln();
    }

    b.writeln('}');
    return b.toString();
  }

  String _buildResponder() {
    final b = StringBuffer();
    final className = '${classElement.name}Responder';
    final defaultTransfer = 'RpcDataTransferMode.${service.transferMode.name}';
    b.writeln(
      'class $className extends RpcResponderContract implements ${classElement.name} {',
    );
    b.writeln('  $className(');
    b.writeln('    this._delegate, {');
    b.writeln('    RpcDataTransferMode dataTransferMode = $defaultTransfer,');
    b.writeln('  }) : super(');
    b.writeln("          '${service.name}',");
    b.writeln('          dataTransferMode: dataTransferMode,');
    b.writeln('        );');
    b.writeln();
    b.writeln('  final ${classElement.name} _delegate;');
    b.writeln();
    b.writeln('  @override');
    b.writeln('  void setup() {');
    for (final method in methods) {
      b.writeln('    ${method.signature.addRegistration(method)};');
    }
    b.writeln('  }');
    b.writeln();

    for (final method in methods) {
      b.writeln(method.signature.responderDelegate(method.declarationName));
      b.writeln();
    }

    b.writeln('}');
    return b.toString();
  }
}

class _SignatureParser {
  _SignatureParser(this.element, this.kind);

  final MethodElement element;
  final RpcMethodKind kind;

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
    _assertSerializable(requestType, request);

    final responseType = _extractFutureGeneric(returnType);
    _assertSerializable(responseType, element);

    return _Signature(
      element: element,
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
    _assertSerializable(requestType, request);

    final responseType = _extractStreamGeneric(returnType);
    _assertSerializable(responseType, element);

    return _Signature(
      element: element,
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
    _assertSerializable(innerRequest, request);

    final responseType = _extractFutureGeneric(returnType);
    _assertSerializable(responseType, element);

    return _Signature(
      element: element,
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
    _assertSerializable(innerRequest, request);

    final responseStream = _expectStream(returnType, 'Bidirectional ответ');
    final innerResponse = responseStream.typeArguments.first;
    _assertSerializable(innerResponse, element);

    return _Signature(
      element: element,
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

  void _assertSerializable(DartType type, Element? errorTarget) {
    if (_serializableChecker.isAssignableFromType(type)) return;
    if (type.isDartCoreString ||
        type.isDartCoreInt ||
        type.isDartCoreDouble ||
        type.isDartCoreBool ||
        type.getDisplayString(withNullability: false) ==
            'Map<String, dynamic>') {
      return;
    }
    throw InvalidGenerationSourceError(
      'Тип ${type.getDisplayString(withNullability: true)} '
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
    required this.kind,
    required this.requestType,
    required this.responseType,
    required this.hasContext,
    this.isRequestStream = false,
    this.isResponseStream = false,
  });

  final MethodElement element;
  final RpcMethodKind kind;
  final DartType requestType;
  final DartType responseType;
  final bool hasContext;
  final bool isRequestStream;
  final bool isResponseStream;

  String callerMethodImpl(_MethodMeta meta) {
    final buffer = StringBuffer();
    final returnType = element.returnType.getDisplayString(
      withNullability: true,
    );
    final requestTypeStr = requestType.getDisplayString(withNullability: true);
    final responseTypeStr = responseType.getDisplayString(
      withNullability: true,
    );

    buffer.writeln('  @override');
    buffer.writeln(
      '  $returnType ${element.name}(${_buildParam(requestTypeStr)}) {',
    );
    buffer.writeln(
      '    return ${_callExpression(meta.methodName, requestTypeStr, responseTypeStr)};',
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
    String rpcMethodName,
    String requestTypeStr,
    String responseTypeStr,
  ) {
    final contextArg = hasContext ? ', context: context' : '';
    final requestVar = isRequestStream ? 'requests' : 'request';

    switch (kind) {
      case RpcMethodKind.unary:
        return 'callUnary<$requestTypeStr, $responseTypeStr>('
            "methodName: '$rpcMethodName', request: $requestVar$contextArg)";
      case RpcMethodKind.serverStream:
        return 'callServerStream<$requestTypeStr, $responseTypeStr>('
            "methodName: '$rpcMethodName', request: $requestVar$contextArg)";
      case RpcMethodKind.clientStream:
        return 'callClientStream<$requestTypeStr, $responseTypeStr>('
            "methodName: '$rpcMethodName', requests: $requestVar$contextArg)";
      case RpcMethodKind.bidirectionalStream:
        return 'callBidirectionalStream<$requestTypeStr, $responseTypeStr>('
            "methodName: '$rpcMethodName', requests: $requestVar$contextArg)";
    }
  }

  String addRegistration(_MethodMeta meta) {
    final requestTypeStr = requestType.getDisplayString(withNullability: true);
    final responseTypeStr = responseType.getDisplayString(
      withNullability: true,
    );
    final methodName = meta.methodName;
    final description = meta.description == null
        ? ''
        : "description: '${_escape(meta.description!)}', ";

    final contextArg = hasContext ? '{RpcContext? context}' : '';
    final handlerName = '_handler_${meta.declarationName}';

    final requestCodec = meta.requestCodecType == null
        ? ''
        : 'requestCodec: const ${meta.requestCodecType!.getDisplayString(withNullability: false)}(), ';
    final responseCodec = meta.responseCodecType == null
        ? ''
        : 'responseCodec: const ${meta.responseCodecType!.getDisplayString(withNullability: false)}(), ';

    switch (kind) {
      case RpcMethodKind.unary:
        return "addUnaryMethod<$requestTypeStr, $responseTypeStr>(methodName: '$methodName', handler: $handlerName, ${description}${requestCodec}${responseCodec})";
      case RpcMethodKind.serverStream:
        return "addServerStreamMethod<$requestTypeStr, $responseTypeStr>(methodName: '$methodName', handler: $handlerName, ${description}${requestCodec}${responseCodec})";
      case RpcMethodKind.clientStream:
        return "addClientStreamMethod<$requestTypeStr, $responseTypeStr>(methodName: '$methodName', handler: $handlerName, ${description}${requestCodec}${responseCodec})";
      case RpcMethodKind.bidirectionalStream:
        return "addBidirectionalStreamMethod<$requestTypeStr, $responseTypeStr>(methodName: '$methodName', handler: $handlerName, ${description}${requestCodec}${responseCodec})";
    }
  }

  String responderDelegate(String originalName) {
    final buffer = StringBuffer();
    final requestTypeStr = requestType.getDisplayString(withNullability: true);
    final responseTypeStr = responseType.getDisplayString(
      withNullability: true,
    );
    final handlerName = '_handler_$originalName';
    final contextParam = hasContext ? ', {RpcContext? context}' : '';
    final requestVar = isRequestStream ? 'requests' : 'request';

    buffer.writeln(
      '  $handlerSignature $handlerName(${handlerParams(requestTypeStr, contextParam, requestVar)}) {',
    );
    final callArgs = hasContext ? '$requestVar, context: context' : requestVar;
    buffer.writeln('    return _delegate.$originalName($callArgs);');
    buffer.writeln('  }');

    return buffer.toString();
  }

  String get handlerSignature {
    final returnType = element.returnType.getDisplayString(
      withNullability: true,
    );
    return returnType;
  }

  String handlerParams(
    String requestTypeStr,
    String contextParam,
    String requestVar,
  ) {
    final firstParam = isRequestStream
        ? 'Stream<$requestTypeStr> $requestVar'
        : '$requestTypeStr $requestVar';
    return '$firstParam$contextParam';
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
  });

  final String methodName;
  final String declarationName;
  final RpcMethodKind kind;
  final _Signature signature;
  final String? description;
  final DartType? requestCodecType;
  final DartType? responseCodecType;
}

extension<E> on Iterable<E> {
  E? firstWhereOrNull(bool Function(E element) test) {
    for (final e in this) {
      if (test(e)) return e;
    }
    return null;
  }
}
