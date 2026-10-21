// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';
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
        RpcMethodType,
        RpcRemoved,
        RpcService,
        RpcServiceKind;
import 'package:rpc_dart_grpc_reflection/rpc_dart_grpc_reflection.dart'
    show
        RpcEnumDescriptor,
        RpcEnumValueDescriptor,
        RpcFieldDescriptor,
        RpcFieldLabel,
        RpcFieldType,
        RpcFileDescriptorBuilder,
        RpcMessageDescriptor,
        RpcMethodDescriptor;
import 'package:source_gen/source_gen.dart';

import '../rpc_dart_generator.dart' show RpcProtoField;

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
// `RpcProtoField` is declared in this generator package (not in rpc_dart core),
// so it is matched by name within `rpc_dart_generator`.
final _protoFieldChecker = const TypeChecker.typeNamed(
  RpcProtoField,
  inPackage: 'rpc_dart_generator',
);

/// The public members of the contract bases the generated classes extend.
///
/// A service method with one of these names cannot be generated. The bases
/// gain no public member in rpc_dart 7.x (see its README), so this list holds
/// for the whole line.
const _contractBaseMembers = {
  'serviceName',
  'dataTransferMode',
  'callerDataTransferMode',
  'endpoint',
  'setup',
  'dispose',
  'addUnaryMethod',
  'addServerStreamMethod',
  'addClientStreamMethod',
  'addBidirectionalMethod',
  'callUnary',
  'callServerStream',
  'callClientStream',
  'callBidirectionalStream',
};

/// Code generator for RPC Dart service contracts annotated with [RpcService].
class RpcDartGenerator extends GeneratorForAnnotation<RpcService> {
  /// Creates the generator.
  const RpcDartGenerator();

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
      throw InvalidGenerationSourceError('@RpcService name must not be empty');
    }

    final transfer = reader.peek('transferMode')?.revive();
    final transferMode = _enumFromAccessor(
      RpcDataTransferMode.values,
      transfer?.accessor,
    );

    final kindRevive = reader.peek('kind')?.revive();
    final serviceKind = _enumFromAccessor(
      RpcServiceKind.values,
      kindRevive?.accessor,
    );

    return _ServiceMeta(
      name: name,
      description: reader.peek('description')?.literalValue as String?,
      transferMode: transferMode ?? RpcDataTransferMode.auto,
      serviceKind: serviceKind ?? RpcServiceKind.unidirectional,
      grpcDescriptor: reader.peek('grpcDescriptor')?.boolValue ?? false,
    );
  }

  /// The value of [values] an accessor such as `RpcMethodType.serverStream`
  /// names, matched by the value's name.
  T? _enumFromAccessor<T extends Enum>(List<T> values, String? accessor) {
    if (accessor == null) return null;
    return values.asNameMap()[accessor.split('.').last];
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
      if (_contractBaseMembers.contains(method.displayName)) {
        throw InvalidGenerationSourceError(
          'Method ${method.displayName} has the name of a member of '
          'RpcCallerContract / RpcResponderContract / RpcPeerContract, which '
          'the generated classes extend. Rename the Dart method; the wire '
          'name in @RpcMethod(name:) can stay as it is.',
          element: method,
        );
      }
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
    final kind =
        _enumFromAccessor(RpcMethodType.values, kindAccessor) ??
        RpcMethodType.unary;

    final transferMode = _enumFromAccessor(
      RpcDataTransferMode.values,
      reader.peek('transferMode')?.revive().accessor,
    );
    final effectiveMode = transferMode ?? serviceMode;

    final signature = _SignatureParser(
      method,
      kind,
      baseName,
      effectiveMode,
    ).parse();

    final requestCodecType = reader.peek('requestCodec')?.typeValue;
    final responseCodecType = reader.peek('responseCodec')?.typeValue;

    return _MethodMeta(
      methodName: name,
      declarationName: method.displayName,
      description: reader.peek('description')?.literalValue as String?,
      signature: signature,
      requestCodecType: requestCodecType,
      responseCodecType: responseCodecType,
      transferMode: transferMode,
    );
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
        final methods = _collectMethods(
          cls,
          baseName,
          serviceMeta.transferMode,
        );
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
      final message =
          ConstantReader(anno).peek('message')?.stringValue ??
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

  late final Set<String> _ambiguousCodecs = _ambiguousCodecNames(methods);

  String get _baseName => _baseNameForClass(classElement);

  String build() {
    final buffer = StringBuffer();
    buffer.writeln("// ignore_for_file: type=lint, unused_element");
    buffer.writeln();

    buffer.writeln(_buildNames());
    buffer.writeln();

    final needsCodecs = methods.any((m) => _usesCodec(m, service.transferMode));
    if (needsCodecs) {
      buffer.writeln(_buildCodecs());
      buffer.writeln();
    }

    if (service.serviceKind == RpcServiceKind.peer) {
      buffer.writeln(_buildPeer());
      buffer.writeln();
      buffer.writeln(_buildPeerCaller());
    } else {
      buffer.writeln(_buildCaller());
      buffer.writeln();
      buffer.writeln(_buildResponder());
    }

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

    if (service.grpcDescriptor) {
      final descriptorLiteral = _GrpcDescriptorBuilder(
        service,
        methods,
      ).buildLiteral();
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
    }

    b.writeln('}');
    return b.toString();
  }

  String _buildCodecs() {
    final b = StringBuffer();
    final className = '${_baseName}Codecs';
    b.writeln('class $className {');
    b.writeln('  const $className._();');

    // Keyed by constant name (see [_codecConstant]): one constant per type for
    // the default codecs, one per method side for an override, so an override
    // never reaches another method that uses the same type.
    final codecMap = <String, _CodecInfo>{};

    void collect(_MethodMeta method, {required bool isResponse}) {
      final type = isResponse
          ? method.signature.responseType
          : method.signature.requestType;
      codecMap.putIfAbsent(
        _codecConstant(
          method,
          isResponse: isResponse,
          ambiguous: _ambiguousCodecs,
        ),
        () => _CodecInfo(
          typeName: type.getDisplayString(),
          type: type,
          customCodecType: isResponse
              ? method.responseCodecType
              : method.requestCodecType,
        ),
      );
    }

    for (final method in methods) {
      if (!_usesCodec(method, service.transferMode)) continue;
      collect(method, isResponse: false);
      collect(method, isResponse: true);
    }

    // Generate constants in alphabetical order for stability.
    final sortedNames = codecMap.keys.toList()..sort();
    for (final codecName in sortedNames) {
      final info = codecMap[codecName]!;
      final typeName = info.typeName;

      if (info.customCodecType != null) {
        b.writeln(
          '  static const $codecName = ${info.customCodecType!.getDisplayString()}();',
        );
      } else if (_hasJsonFactory(info.type)) {
        b.writeln(
          '  static const $codecName = RpcCodec<$typeName>($typeName.fromJson);',
        );
      } else if (info.type.getDisplayString() == 'Map<String, dynamic>') {
        // `Map<String, dynamic>` has no `fromJson` factory. Encode/decode it
        // directly via CBOR instead of referencing a non-existent
        // `Map<String, dynamic>.fromJson`.
        b.writeln(
          '  static const $codecName = RpcBinaryCodec<$typeName>(toBytes: CborCodec.encode, fromBytes: CborCodec.decode);',
        );
      } else {
        // Primitive types (String/int/double/bool) have no `fromJson` factory.
        // Round-trip them through CBOR via the unsafe (non-map) helpers. The
        // decoder is a typed static method here, because `decodeUnsafe`
        // returns `dynamic` and does not fit `$typeName Function(Uint8List)`.
        final decoder =
            '_decode${codecName[0].toUpperCase()}${codecName.substring(1)}';
        // A double goes through num: dart2js cannot tell 2.0 from 2, so a web
        // peer writes an integral double as a CBOR integer.
        final decoded = info.type.isDartCoreDouble
            ? '(CborCodec.decodeUnsafe(bytes) as num).toDouble()'
            : 'CborCodec.decodeUnsafe(bytes) as $typeName';
        b.writeln('  static $typeName $decoder(Uint8List bytes) => $decoded;');
        b.writeln(
          '  static const $codecName = RpcBinaryCodec<$typeName>(toBytes: CborCodec.encodeUnsafe, fromBytes: $decoder);',
        );
      }
    }

    b.writeln('}');
    return b.toString();
  }

  String _buildCaller() {
    final b = StringBuffer();
    final className = '${_baseName}Caller';
    final isVersioned = parentInfo != null;

    b.writeln(
      'class $className extends RpcCallerContract '
      'implements ${classElement.name} {',
    );

    if (isVersioned) {
      b.writeln('  final ${parentInfo!.callerClassName} _parent;');
      b.writeln();
    }

    b.writeln(
      _constructor(
        className,
        endpointType: 'RpcCallerEndpoint',
        parentInit: isVersioned
            ? '_parent = ${parentInfo!.callerClassName}('
                  'endpoint, dataTransferMode: dataTransferMode)'
            : null,
      ),
    );
    b.writeln();

    for (final method in methods) {
      b.writeln(
        method.signature.callerMethodImpl(
          method,
          service.transferMode,
          _ambiguousCodecs,
        ),
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

  /// The constructor of a generated contract: the endpoint when
  /// [endpointType] is given, then `serviceNameOverride` and
  /// `dataTransferMode`, which goes to super as each of [modes].
  String _constructor(
    String className, {
    String? endpointType,
    String? parentInit,
    List<String> modes = const ['dataTransferMode'],
  }) {
    final named =
        'String? serviceNameOverride, '
        'RpcDataTransferMode dataTransferMode = '
        'RpcDataTransferMode.${service.transferMode.name},';
    final params = endpointType == null
        ? '{$named}'
        : '$endpointType endpoint, {$named}';
    final superArgs = [
      'serviceNameOverride ?? ${_baseName}Names.service',
      if (endpointType != null) 'endpoint',
      for (final mode in modes) '$mode: dataTransferMode',
    ].join(', ');
    final initializers = [?parentInit, 'super($superArgs)'].join(', ');
    return '  $className($params) : $initializers;';
  }

  String _buildRemovedMethod(_RemovedMethodInfo info) {
    final method = info.element;
    final returnType = method.returnType.getDisplayString();
    final escaped = _escapeString(info.message);

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

  String _buildPeer() {
    final b = StringBuffer();
    final className = '${_baseName}Peer';

    b.writeln(
      'abstract class $className extends RpcPeerContract '
      'implements ${classElement.name} {',
    );
    b.writeln(
      _constructor(
        className,
        endpointType: 'RpcPeerEndpoint',
        modes: const ['dataTransferMode', 'callerDataTransferMode'],
      ),
    );
    b.writeln();

    // setup() — registers incoming handlers using onXxx names
    b.writeln('  @override');
    b.writeln('  void setup() {');
    for (final method in methods) {
      b.writeln(
        '    ${method.signature.registration(method, _peerHandlerName(method.declarationName), service.transferMode, _ambiguousCodecs)};',
      );
    }
    b.writeln('  }');
    b.writeln();

    // Caller methods — implement interface, call remote peer
    for (final method in methods) {
      b.writeln(
        method.signature.callerMethodImpl(
          method,
          service.transferMode,
          _ambiguousCodecs,
        ),
      );
      b.writeln();
    }

    // Abstract handler declarations — onXxx, user overrides these
    for (final method in methods) {
      b.writeln(method.signature.peerHandlerDecl(method));
      b.writeln();
    }

    b.writeln('}');
    return b.toString();
  }

  String _buildPeerCaller() {
    final b = StringBuffer();
    final className = '${_baseName}PeerCaller';

    b.writeln(
      'class $className extends RpcPeerContract '
      'implements ${classElement.name} {',
    );
    b.writeln(
      _constructor(
        className,
        endpointType: 'RpcPeerEndpoint',
        modes: const ['dataTransferMode', 'callerDataTransferMode'],
      ),
    );
    b.writeln();

    b.writeln('  @override');
    b.writeln('  void setup() {}');
    b.writeln();

    for (final method in methods) {
      b.writeln(
        method.signature.callerMethodImpl(
          method,
          service.transferMode,
          _ambiguousCodecs,
        ),
      );
      b.writeln();
    }

    b.writeln('}');
    return b.toString();
  }

  String _buildResponder() {
    final b = StringBuffer();
    final className = '${_baseName}Responder';
    final isVersioned = parentInfo != null;

    // Versioned responders do not implement the full interface — they only
    // handle their own slice of methods. Implementing the parent interface
    // would force users to implement inherited methods that belong to the
    // parent responder.
    final implementsClause = isVersioned
        ? ''
        : 'implements ${classElement.name} ';

    b.writeln(
      'abstract class $className extends RpcResponderContract '
      '$implementsClause{',
    );
    b.writeln(_constructor(className));
    b.writeln();
    b.writeln('  @override');
    b.writeln('  void setup() {');
    for (final method in methods) {
      b.writeln(
        '    ${method.signature.registration(method, method.declarationName, service.transferMode, _ambiguousCodecs)};',
      );
    }
    b.writeln('  }');

    // Versioned responders need explicit abstract method declarations because
    // they don't implement the interface (which would otherwise provide them).
    if (isVersioned) {
      b.writeln();
      for (final method in methods) {
        b.writeln(method.signature.abstractMethodDecl());
      }
    }

    b.writeln('}');
    return b.toString();
  }
}

class _SignatureParser {
  _SignatureParser(this.element, this.kind, this.baseName, this.effectiveMode);

  final MethodElement element;
  final RpcMethodType kind;
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
      RpcMethodType.unary => _parseUnary(
        requestParam,
        contextParam,
        element.returnType,
      ),
      RpcMethodType.serverStream => _parseServerStream(
        requestParam,
        contextParam,
        element.returnType,
      ),
      RpcMethodType.clientStream => _parseClientStream(
        requestParam,
        contextParam,
        element.returnType,
      ),
      RpcMethodType.bidirectionalStream => _parseBidi(
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
      kind: RpcMethodType.unary,
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
      kind: RpcMethodType.serverStream,
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
      kind: RpcMethodType.clientStream,
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
      kind: RpcMethodType.bidirectionalStream,
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
  final RpcMethodType kind;
  final DartType requestType;
  final DartType responseType;
  final bool hasContext;
  final bool isRequestStream;
  final bool isResponseStream;

  String abstractMethodDecl() {
    final returnType = element.returnType.getDisplayString();
    final requestTypeStr = requestType.getDisplayString();
    return '  $returnType ${element.name}(${_buildParam(requestTypeStr)});';
  }

  /// `onXxx(request, {RpcContext? context})` — abstract handler for peer class.
  String peerHandlerDecl(_MethodMeta meta) {
    final returnType = element.returnType.getDisplayString();
    final requestTypeStr = requestType.getDisplayString();
    final handlerName = _peerHandlerName(meta.declarationName);
    // Always include context in peer handlers regardless of interface signature.
    final param = isRequestStream
        ? 'Stream<$requestTypeStr> requests, {RpcContext? context}'
        : '$requestTypeStr request, {RpcContext? context}';
    return '  $returnType $handlerName($param);';
  }

  /// `addXxxMethod(..., handler: [handlerName], ...)` — one registration in
  /// `setup()`: the method itself in a responder, `onXxx` in a peer.
  String registration(
    _MethodMeta meta,
    String handlerName,
    RpcDataTransferMode serviceMode,
    Set<String> ambiguousCodecs,
  ) {
    final requestTypeStr = requestType.getDisplayString();
    final responseTypeStr = responseType.getDisplayString();
    final description = meta.description == null
        ? ''
        : "description: '${_escapeString(meta.description!)}', ";

    final useCodec = _usesCodec(meta, serviceMode);
    final requestCodec = _codecArg(
      'requestCodec',
      meta,
      isResponse: false,
      useCodec: useCodec,
      ambiguousCodecs: ambiguousCodecs,
    );
    final responseCodec = _codecArg(
      'responseCodec',
      meta,
      isResponse: true,
      useCodec: useCodec,
      ambiguousCodecs: ambiguousCodecs,
    );

    final add = switch (kind) {
      RpcMethodType.unary => 'addUnaryMethod',
      RpcMethodType.serverStream => 'addServerStreamMethod',
      RpcMethodType.clientStream => 'addClientStreamMethod',
      RpcMethodType.bidirectionalStream => 'addBidirectionalMethod',
    };
    return '$add<$requestTypeStr, $responseTypeStr>(methodName: ${baseName}Names.${meta.declarationName}, handler: $handlerName, $description$requestCodec$responseCodec)';
  }

  String callerMethodImpl(
    _MethodMeta meta,
    RpcDataTransferMode serviceMode,
    Set<String> ambiguousCodecs,
  ) {
    final buffer = StringBuffer();
    final returnType = element.returnType.getDisplayString();
    final requestTypeStr = requestType.getDisplayString();
    final responseTypeStr = responseType.getDisplayString();

    buffer.writeln('  @override');
    buffer.writeln(
      '  $returnType ${element.name}(${_buildParam(requestTypeStr)}) {',
    );
    buffer.writeln(
      '    return ${_callExpression(meta, requestTypeStr, responseTypeStr, serviceMode, ambiguousCodecs)};',
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
    Set<String> ambiguousCodecs,
  ) {
    final contextArg = hasContext ? ', context: context' : '';
    final requestVar = isRequestStream ? 'requests' : 'request';
    final useCodec = _usesCodec(meta, serviceMode);
    final requestCodec = _codecArg(
      'requestCodec',
      meta,
      isResponse: false,
      useCodec: useCodec,
      ambiguousCodecs: ambiguousCodecs,
    );
    final responseCodec = _codecArg(
      'responseCodec',
      meta,
      isResponse: true,
      useCodec: useCodec,
      ambiguousCodecs: ambiguousCodecs,
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
      case RpcMethodType.unary:
        return 'callUnary<$requestTypeStr, $responseTypeStr>('
            "${args('request: $requestVar')})";
      case RpcMethodType.serverStream:
        return 'callServerStream<$requestTypeStr, $responseTypeStr>('
            "${args('request: $requestVar')})";
      case RpcMethodType.clientStream:
        return 'callClientStream<$requestTypeStr, $responseTypeStr>('
            "${args('requests: $requestVar')})";
      case RpcMethodType.bidirectionalStream:
        return 'callBidirectionalStream<$requestTypeStr, $responseTypeStr>('
            "${args('requests: $requestVar')})";
    }
  }

  /// `label: <Base>Codecs.<constant>, `, or nothing without codecs.
  String _codecArg(
    String label,
    _MethodMeta meta, {
    required bool isResponse,
    required bool useCodec,
    required Set<String> ambiguousCodecs,
  }) {
    if (!useCodec) return '';
    final constant = _codecConstant(
      meta,
      isResponse: isResponse,
      ambiguous: ambiguousCodecs,
    );
    return '$label: ${baseName}Codecs.$constant, ';
  }
}

class _ServiceMeta {
  _ServiceMeta({
    required this.name,
    required this.transferMode,
    required this.serviceKind,
    required this.grpcDescriptor,
    this.description,
  });

  final String name;
  final RpcDataTransferMode transferMode;
  final RpcServiceKind serviceKind;
  final bool grpcDescriptor;
  final String? description;
}

class _MethodMeta {
  _MethodMeta({
    required this.methodName,
    required this.declarationName,
    required this.signature,
    this.description,
    this.requestCodecType,
    this.responseCodecType,
    this.transferMode,
  });

  final String methodName;
  final String declarationName;
  final _Signature signature;
  final String? description;
  final DartType? requestCodecType;
  final DartType? responseCodecType;
  final RpcDataTransferMode? transferMode;
}

class _CodecInfo {
  _CodecInfo({
    required this.typeName,
    required this.type,
    this.customCodecType,
  });

  final String typeName;
  final DartType type;
  final DartType? customCodecType;
}

class _ParentInfo {
  _ParentInfo({required this.callerClassName, required this.delegateMethods});

  final String callerClassName;
  final List<_MethodMeta> delegateMethods;
}

class _RemovedMethodInfo {
  _RemovedMethodInfo({required this.element, required this.message});

  final MethodElement element;
  final String message;
}

// ---------------------------------------------------------------------------
// gRPC descriptor generation (Tier 2)
// ---------------------------------------------------------------------------

/// Builds a FileDescriptorProto binary at generation time and returns
/// it as a Dart list literal string, e.g. `[10, 5, 101, ...]`.
///
/// Returns null if the service has no methods or a message type cannot be
/// described.
class _GrpcDescriptorBuilder {
  final _ServiceMeta service;
  final List<_MethodMeta> methods;

  _GrpcDescriptorBuilder(this.service, this.methods);

  /// Message types named by the fields described since the last read, so the
  /// file can define them too.
  final Map<String, InterfaceType> _referencedMessages = {};

  /// Enum types named by any field described, defined once in the file.
  final Map<String, EnumElement> _referencedEnums = {};

  /// Proto package for this service, or empty when none is set. Derived from
  /// the dotted service name (everything before the last dot).
  String get _package {
    final lastDot = service.name.lastIndexOf('.');
    return lastDot >= 0 ? service.name.substring(0, lastDot) : '';
  }

  /// Fully-qualified type-name prefix: `.<package>.<simpleName>` when a package
  /// is set, `.<simpleName>` otherwise. Used for both field references and
  /// service input/output references so the descriptor pool can resolve
  /// cross-references between them.
  String _qualifiedTypeName(String simpleName) {
    final prefix = _package.isEmpty ? '' : '$_package.';
    return '.$prefix$simpleName';
  }

  String? buildLiteral() {
    final bytes = _buildBytes();
    if (bytes == null) return null;
    return '[${bytes.join(', ')}]';
  }

  Uint8List? _buildBytes() {
    final lastDot = service.name.lastIndexOf('.');
    final serviceName = lastDot >= 0
        ? service.name.substring(lastDot + 1)
        : service.name;

    // The request and response types, then every message type their fields
    // reach: a field's typeName must resolve inside the file.
    final pending = <String, DartType>{};
    for (final method in methods) {
      for (final t in [
        method.signature.requestType,
        method.signature.responseType,
      ]) {
        pending.putIfAbsent(_typeName(t), () => t);
      }
    }
    if (pending.isEmpty) return null;

    final file = RpcFileDescriptorBuilder(
      name: '${service.name.replaceAll('.', '_')}.proto',
      package: _package,
    );
    final described = <String>{};
    while (pending.isNotEmpty) {
      final name = pending.keys.first;
      final type = pending.remove(name)!;
      if (!described.add(name)) continue;
      final message = _messageDescriptor(name, type);
      if (message == null) return null;
      file.addMessage(message);
      for (final entry in _referencedMessages.entries) {
        if (!described.contains(entry.key)) {
          pending.putIfAbsent(entry.key, () => entry.value);
        }
      }
      _referencedMessages.clear();
    }
    for (final entry in _referencedEnums.entries) {
      file.addEnum(
        RpcEnumDescriptor(
          name: entry.key,
          values: [
            for (final (i, value) in entry.value.constants.indexed)
              RpcEnumValueDescriptor(name: value.name ?? '', number: i),
          ],
        ),
      );
    }
    file.addService(
      name: serviceName,
      methods: [
        for (final method in methods)
          RpcMethodDescriptor(
            name: method.methodName,
            inputType: _qualifiedTypeName(
              _typeName(method.signature.requestType),
            ),
            outputType: _qualifiedTypeName(
              _typeName(method.signature.responseType),
            ),
            clientStreaming: method.signature.isRequestStream,
            serverStreaming: method.signature.isResponseStream,
          ),
      ],
    );
    return file.build();
  }

  RpcMessageDescriptor? _messageDescriptor(String name, DartType type) {
    if (type is! InterfaceType) return null;
    // A bare primitive is not a message. Described as a wrapper with one
    // `value` field, the shape of google.protobuf.StringValue and its
    // siblings; read as a class, String's getters (`hashCode`, `length`, ...)
    // became fields.
    if (type.isDartCoreString ||
        type.isDartCoreInt ||
        type.isDartCoreDouble ||
        type.isDartCoreBool) {
      final field = _fieldDescriptor('value', 1, type);
      if (field == null) return null;
      return RpcMessageDescriptor(name: name, fields: [field]);
    }
    // A type with no stored fields (an Ack, an Empty) is an empty message.
    final fields = _messageFields(type);

    // Determine field numbers. An explicit @RpcProtoField(n) pins the number;
    // otherwise we fall back to declaration order (i + 1), which is unstable
    // across field reorders/inserts/removals and breaks proto wire
    // compatibility. Warn loudly when any field relies on the fallback.
    final usedNumbers = <int, String>{};
    final declarationOrderFields = <String>[];

    final descriptors = <RpcFieldDescriptor>[];
    for (var i = 0; i < fields.length; i++) {
      final fieldName = fields[i].field.name;
      if (fieldName == null) continue;

      final explicit = _explicitFieldNumber(fields[i].field);
      final number = explicit ?? (i + 1);
      if (explicit == null) {
        declarationOrderFields.add(fieldName);
      }

      final clash = usedNumbers[number];
      if (clash != null) {
        log.warning(
          'gRPC descriptor for "$name": field number $number is assigned to '
          'both "$clash" and "$fieldName". Pin unique numbers with '
          '@RpcProtoField to avoid wire-format collisions.',
        );
      }
      usedNumbers[number] = fieldName;

      final descriptor = _fieldDescriptor(fieldName, number, fields[i].type);
      if (descriptor != null) descriptors.add(descriptor);
    }

    if (declarationOrderFields.isNotEmpty) {
      log.warning(
        'gRPC descriptor for "$name": field(s) '
        '${declarationOrderFields.join(', ')} have no @RpcProtoField number '
        'and were numbered by declaration order. This is unstable — '
        'reordering, inserting, or removing a field silently changes the proto '
        'wire format. Annotate these fields with @RpcProtoField(n) to pin '
        'stable numbers.',
      );
    }

    return RpcMessageDescriptor(name: name, fields: descriptors);
  }

  /// The stored instance fields of [type], inherited ones first.
  ///
  /// Declared fields alone miss what a superclass holds: `RpcString` keeps its
  /// `value` in `RpcPrimitiveMessage`, so it read as having no fields and the
  /// whole descriptor was dropped. Synthetic fields, the ones a getter
  /// induces, are not stored and are left out.
  ///
  /// Each field comes with its type as seen from [type], so a generic
  /// superclass's `T value` reads as `String value` for `RpcString`.
  List<({FieldElement field, DartType type})> _messageFields(
    InterfaceType type,
  ) {
    final chain = <InterfaceType>[];
    InterfaceType? current = type;
    while (current != null && !current.isDartCoreObject) {
      chain.add(current);
      current = current.superclass;
    }
    return [
      for (final level in chain.reversed)
        for (final field in level.element.fields)
          // isSynthetic, not its analyzer-10 replacement: the supported range
          // starts at analyzer 9.
          // ignore: deprecated_member_use
          if (!field.isStatic && !field.isSynthetic)
            (
              field: field,
              type: level.getGetter(field.name ?? '')?.returnType ?? field.type,
            ),
    ];
  }

  /// Reads an explicit `@RpcProtoField(number)` from [field], or null when the
  /// field is not annotated.
  int? _explicitFieldNumber(FieldElement field) {
    final anno = _protoFieldChecker.firstAnnotationOfExact(field);
    if (anno == null) return null;
    return ConstantReader(anno).peek('number')?.intValue;
  }

  RpcFieldDescriptor? _fieldDescriptor(String name, int number, DartType type) {
    var label = RpcFieldLabel.optional;
    var actual = type;

    if (actual is InterfaceType && actual.isDartCoreList) {
      label = RpcFieldLabel.repeated;
      actual = actual.typeArguments.isNotEmpty
          ? actual.typeArguments.first
          : actual;
    } else if (actual is InterfaceType &&
        (actual.isDartCoreMap ||
            actual.isDartCoreSet ||
            actual.isDartCoreIterable)) {
      // Map/Set/Iterable cannot be represented as a plain proto field here:
      // a Map needs a synthetic map-entry nested message and Set/Iterable have
      // no direct proto equivalent. Reject rather than emit a garbage typeName
      // like `.Map` that would never resolve in the descriptor pool.
      log.warning(
        'gRPC descriptor: field "$name" has unsupported collection type '
        '"${_typeName(type)}". Map, Set and Iterable are not representable as '
        'proto fields; use a List or a dedicated message type. The field is '
        'left out of the descriptor.',
      );
      return null;
    }

    final RpcFieldType fieldType;
    String? typeName;

    if (actual.isDartCoreString) {
      fieldType = RpcFieldType.typeString;
    } else if (actual.isDartCoreInt) {
      // Dart `int` is 64-bit.
      fieldType = RpcFieldType.typeInt64;
    } else if (actual.isDartCoreDouble) {
      fieldType = RpcFieldType.typeDouble;
    } else if (actual.isDartCoreBool) {
      fieldType = RpcFieldType.typeBool;
    } else if (actual is InterfaceType && actual.element is EnumElement) {
      fieldType = RpcFieldType.typeEnum;
      final enumName = _typeName(actual);
      typeName = _qualifiedTypeName(enumName);
      _referencedEnums[enumName] = actual.element as EnumElement;
    } else if (actual is InterfaceType && actual.element.library.isDartCore) {
      // DateTime, Duration, Uri, BigInt, Object: their fields are private
      // runtime state, not a message anyone can decode.
      log.warning(
        'gRPC descriptor: field "$name" has type "${_typeName(type)}", which '
        'has no proto equivalent. The field is left out of the descriptor.',
      );
      return null;
    } else if (actual is InterfaceType) {
      fieldType = RpcFieldType.typeMessage;
      final messageName = _typeName(actual);
      typeName = _qualifiedTypeName(messageName);
      _referencedMessages[messageName] = actual;
    } else {
      return null;
    }

    return RpcFieldDescriptor(
      name: name,
      number: number,
      type: fieldType,
      label: label,
      typeName: typeName,
    );
  }

  static String _typeName(DartType t) =>
      t.getDisplayString().replaceAll('?', '');
}

/// Escapes special characters for embedding in a single-quoted Dart string
/// literal. Backslash must be escaped first so subsequently inserted
/// backslashes are not double-escaped.
String _escapeString(String value) => value
    .replaceAll('\\', '\\\\')
    .replaceAll(r'$', '\\\$')
    .replaceAll("'", "\\'")
    .replaceAll('\n', '\\n')
    .replaceAll('\r', '\\r')
    .replaceAll('\t', '\\t');

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

/// Whether [meta] is called with codecs: any mode but zero-copy, the method's
/// own over the service's.
bool _usesCodec(_MethodMeta meta, RpcDataTransferMode serviceMode) =>
    (meta.transferMode ?? serviceMode) != RpcDataTransferMode.zeroCopy;

/// The `<Base>Codecs` constant one side of [meta] uses.
///
/// A codec override belongs to its method, so it gets a constant of its own,
/// `requestOf<Method>` / `responseOf<Method>`: a constant per type would hand
/// the override to every method that uses the same type. Every other side
/// shares the type's `codec<Type>` constant.
String _codecConstant(
  _MethodMeta meta, {
  required bool isResponse,
  required Set<String> ambiguous,
}) {
  final override = isResponse ? meta.responseCodecType : meta.requestCodecType;
  if (override != null) {
    final name = meta.declarationName;
    final capitalized = '${name[0].toUpperCase()}${name.substring(1)}';
    return isResponse ? 'responseOf$capitalized' : 'requestOf$capitalized';
  }
  final type = isResponse
      ? meta.signature.responseType
      : meta.signature.requestType;
  return _codecIdentifier(type, ambiguous);
}

/// The peer handler for a method: `onXxx`.
String _peerHandlerName(String declarationName) {
  if (declarationName.isEmpty) return 'onHandle';
  return 'on${declarationName[0].toUpperCase()}${declarationName.substring(1)}';
}

/// Builds a unique codec identifier for [type].
///
/// The simple display name alone is ambiguous: two distinct types that share a
/// simple name but live in different libraries (e.g. `a.Foo` and `b.Foo`) would
/// collapse to one identifier and one would be silently dropped. When such a
/// name appears in [ambiguous], the declaring library URI is folded into a
/// short stable suffix so the colliding types get distinct codec constants.
/// Non-colliding types keep their clean `codec<Name>` identifier.
String _codecIdentifier(DartType type, Set<String> ambiguous) {
  final sanitized = _sanitizeTypeName(type.getDisplayString());
  final base = 'codec$sanitized';
  if (!ambiguous.contains(sanitized)) return base;
  String? libraryUri;
  if (type is InterfaceType) {
    libraryUri = type.element.library.identifier;
  }
  if (libraryUri == null) return base;
  return '${base}_${_stableSuffix(libraryUri)}';
}

/// Sanitized simple names that are shared by more than one distinct type across
/// [methods]. Codec identifiers for these names must be disambiguated.
Set<String> _ambiguousCodecNames(List<_MethodMeta> methods) {
  final byName = <String, Set<String>>{};
  void record(DartType type) {
    final sanitized = _sanitizeTypeName(type.getDisplayString());
    String identity = type.getDisplayString();
    if (type is InterfaceType) {
      identity = '${type.element.library.identifier}#$identity';
    }
    (byName[sanitized] ??= <String>{}).add(identity);
  }

  for (final method in methods) {
    record(method.signature.requestType);
    record(method.signature.responseType);
  }
  return {
    for (final entry in byName.entries)
      if (entry.value.length > 1) entry.key,
  };
}

/// Deterministic short alphanumeric suffix derived from [input], used to
/// disambiguate identifiers that would otherwise collide.
String _stableSuffix(String input) {
  // FNV-1a 32-bit hash kept in the 31-bit positive range; rendered base36 so
  // it is a valid identifier fragment and stable across runs.
  var hash = 0x811c9dc5;
  for (var i = 0; i < input.length; i++) {
    hash ^= input.codeUnitAt(i);
    hash = (hash * 0x01000193) & 0x7fffffff;
  }
  return hash.toRadixString(36);
}

/// Whether [type] declares a usable `fromJson` factory/constructor that the
/// generated `RpcCodec<T>(T.fromJson)` can reference.
///
/// Primitives and `Map<String, dynamic>` pass serialization checks but have no
/// such factory, so emitting `Type.fromJson` for them would not compile.
bool _hasJsonFactory(DartType type) {
  if (type is! InterfaceType) return false;
  if (type.isDartCoreString ||
      type.isDartCoreInt ||
      type.isDartCoreDouble ||
      type.isDartCoreBool ||
      type.isDartCoreMap ||
      type.isDartCoreList) {
    return false;
  }
  // User-declared request/response types are required to implement
  // IRpcSerializable (verified earlier by _assertSerializable) and therefore
  // expose a `fromJson` factory the generated decoder can reference.
  return true;
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
