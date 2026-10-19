// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
// SPDX-License-Identifier: MIT

import 'package:rpc_dart/transport.dart';

// Minimal protobuf binary parser — only the fields needed for gRPC reflection.
//
// FileDescriptorProto fields parsed:
//   1  = name (string)
//   2  = package (string)
//   3  = dependency (repeated string)
//   4  = message_type (repeated DescriptorProto)
//   5  = enum_type (repeated EnumDescriptorProto)
//   6  = service (repeated ServiceDescriptorProto)
//
// DescriptorProto fields parsed (recursive):
//   1  = name (string)
//   3  = nested_type (repeated DescriptorProto)
//   4  = enum_type (repeated EnumDescriptorProto)

/// Parsed representation of a FileDescriptorProto (fields used for reflection).
class ParsedFileDescriptor {
  final String name;
  final String package;

  /// Proto import paths, e.g. `['google/protobuf/timestamp.proto']`.
  final List<String> dependencies;

  final List<String> services;

  /// Method names per service, relative to the package —
  /// e.g. `{'EchoService': ['Echo', 'EchoStream']}`.
  ///
  /// Carried so a fully-qualified METHOD can be indexed for
  /// `file_containing_symbol`, which the reflection proto documents as
  /// accepting `<package>.<service>[.<method>]`. Defaulted rather than
  /// required, so adding it does not break an existing construction.
  final Map<String, List<String>> serviceMethods;

  /// All message type names including nested, relative to package.
  /// e.g. `['Outer', 'Outer.Inner']` for package `foo.v1`.
  final List<String> messageTypes;

  /// All enum type names including nested, relative to package.
  final List<String> enumTypes;

  final Uint8List rawBytes;

  const ParsedFileDescriptor({
    required this.name,
    required this.package,
    required this.dependencies,
    required this.services,
    required this.messageTypes,
    required this.enumTypes,
    required this.rawBytes,
    this.serviceMethods = const {},
  });
}

/// Parses a single serialized FileDescriptorProto.
ParsedFileDescriptor parseFileDescriptorProto(Uint8List bytes) =>
    _parseFileDescriptorProto(bytes);

ParsedFileDescriptor _parseFileDescriptorProto(Uint8List bytes) {
  final reader = RpcProtoReader(bytes);
  var name = '';
  var package = '';
  final dependencies = <String>[];
  final services = <String>[];
  final serviceMethods = <String, List<String>>{};
  final messageTypes = <String>[];
  final enumTypes = <String>[];

  while (!reader.atEnd) {
    final (field: fieldNumber, :wireType) = reader.readTag();

    switch (fieldNumber) {
      case 1 when wireType == RpcProtoWireType.lengthDelimited:
        name = reader.readString();
      case 2 when wireType == RpcProtoWireType.lengthDelimited:
        package = reader.readString();
      case 3 when wireType == RpcProtoWireType.lengthDelimited:
        // repeated string dependency
        dependencies.add(reader.readString());
      case 4 when wireType == RpcProtoWireType.lengthDelimited:
        // repeated DescriptorProto message_type — collect names recursively
        _collectAllTypeNames(reader.readBytes(), '', messageTypes, enumTypes);
      case 5 when wireType == RpcProtoWireType.lengthDelimited:
        // repeated EnumDescriptorProto enum_type (file-level)
        final enumName = _parseNameField(reader.readBytes());
        if (enumName.isNotEmpty) enumTypes.add(enumName);
      case 6 when wireType == RpcProtoWireType.lengthDelimited:
        // repeated ServiceDescriptorProto service
        final svcBytes = reader.readBytes();
        final svcName = _parseNameField(svcBytes);
        if (svcName.isNotEmpty) {
          services.add(svcName);
          final methods = _parseServiceMethodNames(svcBytes);
          if (methods.isNotEmpty) serviceMethods[svcName] = methods;
        }
      default:
        reader.skip(wireType);
    }
  }

  return ParsedFileDescriptor(
    name: name,
    package: package,
    dependencies: dependencies,
    services: services,
    serviceMethods: serviceMethods,
    messageTypes: messageTypes,
    enumTypes: enumTypes,
    rawBytes: bytes,
  );
}

/// Recursively collects all message and enum type names from a DescriptorProto.
///
/// [prefix] is the dotted path of enclosing messages, e.g. `'Outer.'`.
/// Names are appended to [messages] and [enums] as `prefix + name`.
void _collectAllTypeNames(
  Uint8List bytes,
  String prefix,
  List<String> messages,
  List<String> enums,
) {
  final reader = RpcProtoReader(bytes);
  var name = '';
  final nestedMessageBytes = <Uint8List>[];
  final nestedEnumBytes = <Uint8List>[];

  while (!reader.atEnd) {
    final (field: fn, wireType: wt) = reader.readTag();

    switch (fn) {
      case 1 when wt == RpcProtoWireType.lengthDelimited:
        name = reader.readString();
      case 3 when wt == RpcProtoWireType.lengthDelimited:
        // nested_type (repeated DescriptorProto)
        nestedMessageBytes.add(reader.readBytes());
      case 4 when wt == RpcProtoWireType.lengthDelimited:
        // enum_type (repeated EnumDescriptorProto)
        nestedEnumBytes.add(reader.readBytes());
      default:
        reader.skip(wt);
    }
  }

  if (name.isEmpty) return;

  final fqn = '$prefix$name';
  messages.add(fqn);

  final nestedPrefix = '$fqn.';
  for (final nb in nestedMessageBytes) {
    _collectAllTypeNames(nb, nestedPrefix, messages, enums);
  }
  for (final eb in nestedEnumBytes) {
    final enumName = _parseNameField(eb);
    if (enumName.isNotEmpty) enums.add('$nestedPrefix$enumName');
  }
}

/// Extracts the method names from a serialized `ServiceDescriptorProto`.
///
/// `ServiceDescriptorProto.method` is field 2, and each `MethodDescriptorProto`
/// carries its name in field 1.
///
/// Needed because `file_containing_symbol` accepts a fully-qualified METHOD
/// name -- the reflection proto documents the symbol as
/// `<package>.<service>[.<method>]` -- and that is how `grpcurl describe
/// pkg.Service.Method` resolves. Without the method names there is nothing to
/// index them under.
List<String> _parseServiceMethodNames(Uint8List bytes) {
  final methods = <String>[];
  final reader = RpcProtoReader(bytes);
  while (!reader.atEnd) {
    final (field: fieldNumber, :wireType) = reader.readTag();
    if (fieldNumber == 2 && wireType == RpcProtoWireType.lengthDelimited) {
      final name = _parseNameField(reader.readBytes());
      if (name.isNotEmpty) methods.add(name);
      continue;
    }
    reader.skip(wireType);
  }
  return methods;
}

/// Reads field 1 (string name) from a proto message.
String _parseNameField(Uint8List bytes) {
  final reader = RpcProtoReader(bytes);
  while (!reader.atEnd) {
    final (field: fieldNumber, :wireType) = reader.readTag();
    if (fieldNumber == 1 && wireType == RpcProtoWireType.lengthDelimited) {
      return reader.readString();
    }
    reader.skip(wireType);
  }
  return '';
}
