// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/dart/element/type.dart';
import 'package:build/build.dart';
import 'package:dart_style/dart_style.dart';
import 'package:pub_semver/pub_semver.dart' show Version;
import 'package:rpc_dart/rpc_dart.dart'
    show
        IRpcSerializable,
        RpcContext,
        RpcDataTransferMode,
        RpcMethod,
        RpcMethodKind,
        RpcRemoved,
        RpcService;
import 'package:source_gen/source_gen.dart';

final _rpcMethodChecker = const TypeChecker.typeNamed(
  RpcMethod,
  inPackage: 'rpc_dart',
);
final _rpcServiceChecker = const TypeChecker.typeNamed(
  RpcService,
  inPackage: 'rpc_dart',
);
final _rpcRemovedChecker = const TypeChecker.typeNamed(
  RpcRemoved,
  inPackage: 'rpc_dart',
);
final _serializableChecker = const TypeChecker.typeNamed(
  IRpcSerializable,
  inPackage: 'rpc_dart',
);
final _contextChecker = const TypeChecker.typeNamed(
  RpcContext,
  inPackage: 'rpc_dart',
);

/// Code generator for RPC Dart service contracts annotated with [RpcService].
class RpcDartGenerator extends GeneratorForAnnotation<RpcService> {
  /// Creates an [RpcDartGenerator] with optional [BuilderOptions].
  RpcDartGenerator([BuilderOptions? options])
      : _options = options ?? BuilderOptions({});

  // BuilderOptions reserved for future config.
  // ignore: unused_field
  final BuilderOptions _options;

  @override
  FutureOr<String> generateForAnnotatedElement(
    Element element,
    ConstantReader annotation,
    BuildStep buildStep,
  ) {
    if (element is! ClassElement) {
      throw InvalidGenerationSourceError(
        '@RpcService can only be applied to a class or interface',
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

    final parentInfo = _buildParentInfo(element);
    final removedMethods = _collectRemovedMethods(element);

    final emitter = _Emitter(
      classElement: element,
      service: serviceMeta,
      methods: methods,
      parentInfo: parentInfo,
      removedMethods: removedMethods,
    );

    final raw = emitter.build();
    return DartFormatter(languageVersion: Version(3, 9, 0)).format(raw);
  }

  _ServiceMeta _parseService(ConstantReader reader) {
    final name = reader.peek('name')?.stringValue ?? '';
    if (name.trim().isEmpty) {
      throw InvalidGenerationSourceError(
        '@RpcService name must not be empty',
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

  // Delegates to the top-level helper.
  String _baseNameFor(ClassElement element) => _baseNameForClass(element);

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
        'Class ${element.name} is annotated with @RpcService but has no @RpcMethod methods',
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
        'Method ${method.name} must have a non-empty name in @RpcMethod',
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

  _ParentInfo? _buildParentInfo(ClassElement element) {
    ClassElement? directParent;
    for (final iface in element.interfaces) {
      final ifaceEl = iface.element;
      if (ifaceEl is ClassElement &&
          _rpcServiceChecker.firstAnnotationOf(ifaceEl) != null) {
        directParent = ifaceEl;
        break;
      }
    }

    if (directParent == null) return null;

    final ownMethodNames = element.methods.map((m) => m.name).toSet();

    final delegateMethods = <_MethodMeta>[];
    final seen = <String>{};

    void walk(ClassElement cls) {
      final anno = _rpcServiceChecker.firstAnnotationOf(cls);
      if (anno != null) {
        final serviceMeta = _parseService(ConstantReader(anno));
        final baseName = _baseNameFor(cls);
        final methods =
            _collectMethods(cls, baseName, serviceMeta.transferMode);
        for (final m in methods) {
          if (!ownMethodNames.contains(m.declarationName) &&
              !seen.contains(m.declarationName)) {
            seen.add(m.declarationName);
            delegateMethods.add(m);
          }
        }
      }
      for (final iface in cls.interfaces) {
        if (iface.element is ClassElement) {
          walk(iface.element as ClassElement);
        }
      }
    }

    walk(directParent);

    return _ParentInfo(
      callerClassName: '${_baseNameFor(directParent)}Caller',
      delegateMethods: delegateMethods,
    );
  }

  List<_RemovedMethodInfo> _collectRemovedMethods(ClassElement element) {
    final result = <_RemovedMethodInfo>[];
    for (final method in element.methods) {
      final anno = _rpcRemovedChecker.firstAnnotationOf(method);
      if (anno == null) continue;
      final message = ConstantReader(anno).peek('message')?.stringValue ??
          '${method.name} has been removed.';
      result.add(_RemovedMethodInfo(element: method, message: message));
    }
    return result;
  }

  void _validateUniqueMethodNames(List<_MethodMeta> methods) {
    final names = <String, MethodElement>{};
    for (final method in methods) {
      final existing = names[method.methodName];
      if (existing != null) {
        throw InvalidGenerationSourceError(
          'Duplicate RPC method name "${method.methodName}" '
          'in ${method.declarationName} and ${existing.name}',
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
    this.parentInfo,
    this.removedMethods = const [],
  });

  final ClassElement classElement;
  final _ServiceMeta service;
  final List<_MethodMeta> methods;
  final _ParentInfo? parentInfo;
  final List<_RemovedMethodInfo> removedMethods;

  String get _baseName => _baseNameForClass(classElement);

  bool _shouldUseCodec(
    _MethodMeta meta,
    RpcDataTransferMode effectiveMode,
  ) {
    final methodMode = meta.transferMode ?? effectiveMode;
    return methodMode != RpcDataTransferMode.zeroCopy;
  }

  String build() {
    final buffer = StringBuffer();
    buffer.writeln("// ignore_for_file: type=lint, unused_element");
    buffer.writeln();

    buffer.writeln(_buildNames());
    buffer.writeln();

    final needsCodecs = methods.any(
        (m) => _shouldUseCodec(m, service.transferMode));
    if (needsCodecs) {
      buffer.writeln(_buildCodecs());
      buffer.writeln();
    }

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
    b.writeln("  static const service = '${_escapeString(service.name)}';");
    b.writeln(
      r"  static String instance(String suffix) => '$service\_$suffix';",
    );
    for (final method in methods) {
      b.writeln(
        "  static const ${method.declarationName} = '${_escapeString(method.methodName)}';",
      );
    }

    final descriptorLiteral =
        _GrpcDescriptorBuilder(service, methods).buildLiteral();
    if (descriptorLiteral != null) {
      b.writeln();
      b.writeln(
        '  /// FileDescriptorProto bytes for gRPC Server Reflection.',
      );
      b.writeln(
        '  /// Register with: registry.addFileDescriptor($className.grpcDescriptor)',
      );
      b.writeln(
        '  static final grpcDescriptor = Uint8List.fromList(const $descriptorLiteral);',
      );
    }

    b.writeln('}');
    return b.toString();
  }

  String _buildCodecs() {
    final b = StringBuffer();
    final className = '${_baseName}Codecs';
    b.writeln('class $className {');
    b.writeln('  const $className._();');

    // Collect unique types with their codecs.
    final codecMap = <String, _CodecInfo>{};

    for (final method in methods) {
      final effectiveMode = method.transferMode ?? service.transferMode;
      if (!_shouldUseCodec(method, effectiveMode)) {
        continue;
      }

      final requestTypeStr = method.signature.requestType.getDisplayString();
      final responseTypeStr = method.signature.responseType.getDisplayString();

      // Add request codec if not already present.
      if (!codecMap.containsKey(requestTypeStr)) {
        codecMap[requestTypeStr] = _CodecInfo(
          typeName: requestTypeStr,
          customCodecType: method.requestCodecType,
        );
      }

      // Add response codec if not already present.
      if (!codecMap.containsKey(responseTypeStr)) {
        codecMap[responseTypeStr] = _CodecInfo(
          typeName: responseTypeStr,
          customCodecType: method.responseCodecType,
        );
      }
    }

    // Generate constants in alphabetical order for stability.
    final sortedTypes = codecMap.keys.toList()..sort();
    for (final typeName in sortedTypes) {
      final info = codecMap[typeName]!;
      final codecName = 'codec${_sanitizeTypeName(typeName)}';

      if (info.customCodecType != null) {
        b.writeln(
            '  static const $codecName = ${info.customCodecType!.getDisplayString()}();');
      } else {
        b.writeln(
            '  static const $codecName = RpcCodec<$typeName>.withDecoder($typeName.fromJson);');
      }
    }

    b.writeln('}');
    return b.toString();
  }

  String _buildCaller() {
    final b = StringBuffer();
    final className = '${_baseName}Caller';
    final defaultTransfer = 'RpcDataTransferMode.${service.transferMode.name}';
    final isVersioned = parentInfo != null;

    b.writeln(
      'class $className extends RpcCallerContract '
      'implements ${classElement.name} {',
    );

    if (isVersioned) {
      b.writeln('  final ${parentInfo!.callerClassName} _parent;');
      b.writeln();
    }

    b.writeln('  $className(');
    b.writeln('    RpcCallerEndpoint endpoint, {');
    b.writeln('    String? serviceNameOverride,');
    b.writeln('    RpcDataTransferMode dataTransferMode = $defaultTransfer,');

    if (isVersioned) {
      b.writeln('  }) : _parent = ${parentInfo!.callerClassName}(');
      b.writeln('          endpoint,');
      b.writeln('          dataTransferMode: dataTransferMode,');
      b.writeln('        ),');
      b.writeln('        super(');
    } else {
      b.writeln('  }) : super(');
    }

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

    if (isVersioned) {
      for (final method in parentInfo!.delegateMethods) {
        b.writeln(_buildDelegateMethod(method));
        b.writeln();
      }
    }

    for (final removed in removedMethods) {
      b.writeln(_buildRemovedMethod(removed));
      b.writeln();
    }

    b.writeln('}');
    return b.toString();
  }

  String _buildRemovedMethod(_RemovedMethodInfo info) {
    final method = info.element;
    final returnType = method.returnType.getDisplayString();
    final escaped = info.message.replaceAll("'", "\\'");

    final positional = method.formalParameters
        .where((p) => p.isPositional)
        .map((p) => '${p.type.getDisplayString()} ${p.name}')
        .join(', ');
    final named = method.formalParameters
        .where((p) => p.isNamed)
        .map((p) => '${p.type.getDisplayString()} ${p.name}')
        .join(', ');
    final params = named.isEmpty
        ? positional
        : positional.isEmpty
            ? '{$named}'
            : '$positional, {$named}';

    return "  @Deprecated('$escaped')\n"
        '  @override\n'
        '  $returnType ${method.name}($params) =>\n'
        "      throw UnsupportedError('$escaped');";
  }

  String _buildDelegateMethod(_MethodMeta method) {
    final sig = method.signature;
    final returnType = sig.element.returnType.getDisplayString();
    final requestTypeStr = sig.requestType.getDisplayString();
    final contextParam = sig.hasContext ? ', {RpcContext? context}' : '';
    final contextArg = sig.hasContext ? ', context: context' : '';

    if (sig.isRequestStream) {
      return '  @override\n'
          '  $returnType ${sig.element.name}('
          'Stream<$requestTypeStr> requests$contextParam) {\n'
          '    return _parent.${sig.element.name}(requests$contextArg);\n'
          '  }';
    } else {
      return '  @override\n'
          '  $returnType ${sig.element.name}('
          '$requestTypeStr request$contextParam) {\n'
          '    return _parent.${sig.element.name}(request$contextArg);\n'
          '  }';
    }
  }

  String _buildResponder() {
    final b = StringBuffer();
    final className = '${_baseName}Responder';
    final defaultTransfer = 'RpcDataTransferMode.${service.transferMode.name}';
    final isVersioned = parentInfo != null;

    // Versioned responders do not implement the full interface — they only
    // handle their own slice of methods. Implementing the parent interface
    // would force users to implement inherited methods that belong to the
    // parent responder.
    final implementsClause =
        isVersioned ? '' : 'implements ${classElement.name} ';

    b.writeln(
      'abstract class $className extends RpcResponderContract '
      '$implementsClause{',
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

    // Versioned responders need explicit abstract method declarations because
    // they don't implement the interface (which would otherwise provide them).
    if (isVersioned) {
      b.writeln();
      for (final method in methods) {
        b.writeln(method.signature.abstractMethodDecl(method));
      }
    }

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
        'context parameter must be RpcContext?',
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
        'Method ${element.name} must have at least one request parameter',
        element: element,
      );
    }

    if (positional.length > 1) {
      throw InvalidGenerationSourceError(
        'Method ${element.name} must have exactly one positional request parameter',
        element: element,
      );
    }

    if (!positional.first.isRequiredPositional) {
      throw InvalidGenerationSourceError(
        'Request parameter of ${element.name} must be a required positional parameter',
        element: positional.first,
      );
    }

    final forbiddenNamed = named.where((p) => p.name != 'context').toList();
    if (forbiddenNamed.isNotEmpty) {
      throw InvalidGenerationSourceError(
        'Method ${element.name} only supports the named parameter "context"',
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
        'Unary method ${element.name} must accept a request parameter',
        element: element,
      );
    }

    final requestType = _expectNonStream(request.type, 'Unary request');
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
        'Server stream method ${element.name} must accept a request parameter',
        element: element,
      );
    }
    final requestType = _expectNonStream(request.type, 'ServerStream request');
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
    final streamType = _expectStream(request?.type, 'ClientStream request');
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
    final streamType = _expectStream(request?.type, 'Bidirectional request');
    final innerRequest = streamType.typeArguments.first;
    _assertSerializable(innerRequest, request, effectiveMode);

    final responseStream = _expectStream(returnType, 'Bidirectional response');
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
        '$context must not be a Stream',
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
      '$context must be Stream<T>',
      element: element,
    );
  }

  InterfaceType _expectFuture(DartType type, String context) {
    if (type is InterfaceType && type.isDartAsyncFuture) {
      return type;
    }
    throw InvalidGenerationSourceError(
      '$context must return Future<T>',
      element: element,
    );
  }

  DartType _extractFutureGeneric(DartType type) {
    if (type is InterfaceType && type.isDartAsyncFutureOr) {
      return type.typeArguments.first;
    }
    final future = _expectFuture(type, 'Return type');
    return future.typeArguments.first;
  }

  DartType _extractStreamGeneric(DartType type) {
    final stream = _expectStream(type, 'Return type');
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
      'Type ${type.getDisplayString()} '
      'does not implement IRpcSerializable',
      element: errorTarget ?? element,
    );
  }

  bool _isStream(DartType type) {
    return type.isDartAsyncStream;
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

  String abstractMethodDecl(_MethodMeta meta) {
    final returnType = element.returnType.getDisplayString();
    final requestTypeStr = requestType.getDisplayString();
    return '  $returnType ${element.name}(${_buildParam(requestTypeStr)});';
  }

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
      methodDeclarationName: meta.declarationName,
    );
    final responseCodec = _codecString(
      isResponse: true,
      useDefault: useCodec,
      providedCodecType: meta.responseCodecType,
      targetType: responseTypeStr,
      methodDeclarationName: meta.declarationName,
    );

    switch (kind) {
      case RpcMethodKind.unary:
        return "addUnaryMethod<$requestTypeStr, $responseTypeStr>(methodName: ${baseName}Names.${meta.declarationName}, handler: ${meta.declarationName}, $description$requestCodec$responseCodec)";
      case RpcMethodKind.serverStream:
        return "addServerStreamMethod<$requestTypeStr, $responseTypeStr>(methodName: ${baseName}Names.${meta.declarationName}, handler: ${meta.declarationName}, $description$requestCodec$responseCodec)";
      case RpcMethodKind.clientStream:
        return "addClientStreamMethod<$requestTypeStr, $responseTypeStr>(methodName: ${baseName}Names.${meta.declarationName}, handler: ${meta.declarationName}, $description$requestCodec$responseCodec)";
      case RpcMethodKind.bidirectionalStream:
        return "addBidirectionalMethod<$requestTypeStr, $responseTypeStr>(methodName: ${baseName}Names.${meta.declarationName}, handler: ${meta.declarationName}, $description$requestCodec$responseCodec)";
    }
  }

  bool _shouldUseCodec(_MethodMeta meta, RpcDataTransferMode effectiveMode) {
    if (effectiveMode == RpcDataTransferMode.zeroCopy) return false;
    if (meta.requestCodecType != null || meta.responseCodecType != null) {
      return true;
    }
    // transferMode auto/codec — use default RpcCodec
    return true;
  }

  String _codecString({
    required bool isResponse,
    required bool useDefault,
    required DartType? providedCodecType,
    required String targetType,
    required String methodDeclarationName,
  }) {
    final label = isResponse ? 'responseCodec' : 'requestCodec';
    if (!useDefault) return '';
    return '$label: ${baseName}Codecs.codec${_sanitizeTypeName(targetType)}, ';
  }

  String _codecArg({
    required String label,
    required bool isResponse,
    required _MethodMeta meta,
    required String targetType,
    required bool useCodec,
  }) {
    if (!useCodec) return '';
    return '$label: ${baseName}Codecs.codec${_sanitizeTypeName(targetType)}, ';
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

class _CodecInfo {
  _CodecInfo({
    required this.typeName,
    this.customCodecType,
  });

  final String typeName;
  final DartType? customCodecType;
}

class _ParentInfo {
  _ParentInfo({
    required this.callerClassName,
    required this.delegateMethods,
  });

  final String callerClassName;
  final List<_MethodMeta> delegateMethods;
}

class _RemovedMethodInfo {
  _RemovedMethodInfo({
    required this.element,
    required this.message,
  });

  final MethodElement element;
  final String message;
}

// ---------------------------------------------------------------------------
// gRPC descriptor generation (Tier 2)
// ---------------------------------------------------------------------------

/// Builds a FileDescriptorProto binary at generation time and returns
/// it as a Dart list literal string, e.g. `[10, 5, 101, ...]`.
///
/// Returns null if the descriptor cannot be built (e.g. zeroCopy mode,
/// unrepresentable field types).
class _GrpcDescriptorBuilder {
  final _ServiceMeta service;
  final List<_MethodMeta> methods;

  _GrpcDescriptorBuilder(this.service, this.methods);

  String? buildLiteral() {
    final bytes = _buildBytes();
    if (bytes == null) return null;
    return '[${bytes.join(', ')}]';
  }

  Uint8List? _buildBytes() {
    final lastDot = service.name.lastIndexOf('.');
    final package = lastDot >= 0 ? service.name.substring(0, lastDot) : '';
    final serviceName =
        lastDot >= 0 ? service.name.substring(lastDot + 1) : service.name;

    // Collect unique non-zeroCopy message types.
    final messageTypes = <String, DartType>{};
    for (final method in methods) {
      for (final t in [
        method.signature.requestType,
        method.signature.responseType,
      ]) {
        final name = _typeName(t);
        messageTypes.putIfAbsent(name, () => t);
      }
    }
    if (messageTypes.isEmpty) return null;

    final messageBytesList = <Uint8List>[];
    for (final entry in messageTypes.entries) {
      final bytes = _buildMessageDescriptor(entry.key, entry.value);
      if (bytes == null) return null;
      messageBytesList.add(bytes);
    }

    final serviceBytes = _buildServiceDescriptor(serviceName, package);

    final w = _ProtoWriter();
    w.writeString(1, '${service.name.replaceAll('.', '_')}.proto');
    w.writeString(2, package);
    for (final msg in messageBytesList) {
      w.writeBytes(4, msg);
    }
    w.writeBytes(6, serviceBytes);
    return w.toBytes();
  }

  Uint8List? _buildMessageDescriptor(String name, DartType type) {
    if (type is! InterfaceType) return null;
    final fields =
        type.element.fields.where((f) => !f.isStatic).toList();
    if (fields.isEmpty) return null;

    final w = _ProtoWriter();
    w.writeString(1, name);
    for (var i = 0; i < fields.length; i++) {
      final fieldName = fields[i].name;
      if (fieldName == null) continue;
      final fb = _buildFieldDescriptor(fieldName, i + 1, fields[i].type);
      if (fb != null) w.writeBytes(2, fb);
    }
    return w.toBytes();
  }

  Uint8List? _buildFieldDescriptor(String name, int number, DartType type) {
    var label = 1; // LABEL_OPTIONAL
    var actual = type;

    if (actual is InterfaceType && actual.isDartCoreList) {
      label = 3; // LABEL_REPEATED
      actual = actual.typeArguments.isNotEmpty ? actual.typeArguments.first : actual;
    }

    int fieldType;
    String? typeName;

    if (actual.isDartCoreString) {
      fieldType = 9;
    } else if (actual.isDartCoreInt) {
      fieldType = 5;
    } else if (actual.isDartCoreDouble) {
      fieldType = 1;
    } else if (actual.isDartCoreBool) {
      fieldType = 8;
    } else if (actual is InterfaceType) {
      fieldType = 11; // TYPE_MESSAGE
      typeName = '.${actual.element.name ?? ''}';
    } else {
      return null;
    }

    final w = _ProtoWriter();
    w.writeString(1, name);
    w.writeInt32(3, number);
    w.writeInt32(4, label);
    w.writeInt32(5, fieldType);
    if (typeName != null) w.writeString(6, typeName);
    w.writeString(10, _toJsonName(name));
    return w.toBytes();
  }

  Uint8List _buildServiceDescriptor(String serviceName, String package) {
    final prefix = package.isEmpty ? '' : '$package.';
    final w = _ProtoWriter();
    w.writeString(1, serviceName);
    for (final method in methods) {
      final mw = _ProtoWriter();
      mw.writeString(1, method.methodName);
      mw.writeString(2, '.$prefix${_typeName(method.signature.requestType)}');
      mw.writeString(3, '.$prefix${_typeName(method.signature.responseType)}');
      if (method.signature.isRequestStream) mw.writeBool(5, true);
      if (method.signature.isResponseStream) mw.writeBool(6, true);
      w.writeBytes(2, mw.toBytes());
    }
    return w.toBytes();
  }

  static String _typeName(DartType t) =>
      t.getDisplayString().replaceAll('?', '');

  static String _toJsonName(String name) => name.replaceAllMapped(
    RegExp(r'_([a-z])'),
    (m) => m.group(1)!.toUpperCase(),
  );
}

/// Minimal protobuf binary encoder (build-time only, not for runtime use).
class _ProtoWriter {
  final _buf = <int>[];

  void writeVarint(int value) {
    while (value > 0x7F) {
      _buf.add((value & 0x7F) | 0x80);
      value >>= 7;
    }
    _buf.add(value & 0x7F);
  }

  void _tag(int fieldNumber, int wireType) =>
      writeVarint((fieldNumber << 3) | wireType);

  void writeString(int fieldNumber, String value) {
    if (value.isEmpty) return;
    final encoded = utf8.encode(value);
    _tag(fieldNumber, 2);
    writeVarint(encoded.length);
    _buf.addAll(encoded);
  }

  void writeBytes(int fieldNumber, Uint8List value) {
    if (value.isEmpty) return;
    _tag(fieldNumber, 2);
    writeVarint(value.length);
    _buf.addAll(value);
  }

  void writeBool(int fieldNumber, bool value) {
    if (!value) return;
    _tag(fieldNumber, 0);
    writeVarint(1);
  }

  void writeInt32(int fieldNumber, int value) {
    _tag(fieldNumber, 0);
    writeVarint(value);
  }

  Uint8List toBytes() => Uint8List.fromList(_buf);
}

/// Escapes single quotes in a string for use in Dart string literals.
String _escapeString(String value) => value.replaceAll("'", "\\'");

/// Strips leading `I` from interface names (e.g. `ICalculator` -> `Calculator`).
String _baseNameForClass(ClassElement element) {
  final name = element.displayName;
  if (name.length > 1 &&
      name.startsWith('I') &&
      RegExp(r'[A-Z]').hasMatch(name[1])) {
    return name.substring(1);
  }
  return name;
}

/// Sanitizes a Dart type name into a valid identifier fragment.
///
/// Strips generic brackets, nullable markers, and special characters.
/// Example: `Map<String, dynamic>?` -> `MapStringDynamic`.
String _sanitizeTypeName(String typeName) {
  return typeName
      .replaceAll('?', '')
      .replaceAll('<', '_')
      .replaceAll('>', '')
      .replaceAll(', ', '_')
      .replaceAll(',', '_')
      .replaceAll(' ', '');
}

extension<E> on Iterable<E> {
  E? firstWhereOrNull(bool Function(E element) test) {
    for (final e in this) {
      if (test(e)) return e;
    }
    return null;
  }
}
