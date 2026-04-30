// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
// SPDX-License-Identifier: MIT

import 'dart:typed_data';

import 'proto_writer.dart';

// ---------------------------------------------------------------------------
// Protobuf field type constants (FieldDescriptorProto.Type)
// ---------------------------------------------------------------------------

/// Protobuf scalar field types for use in [RpcFieldDescriptor].
enum RpcFieldType {
  typeDouble(1),
  typeFloat(2),
  typeInt64(3),
  typeUint64(4),
  typeInt32(5),
  typeBool(8),
  typeString(9),
  typeMessage(11),
  typeBytes(12),
  typeUint32(13);

  const RpcFieldType(this.value);
  final int value;
}

/// Protobuf field label (optional or repeated).
enum RpcFieldLabel {
  optional(1),
  repeated(3);

  const RpcFieldLabel(this.value);
  final int value;
}

// ---------------------------------------------------------------------------
// Descriptor builders
// ---------------------------------------------------------------------------

/// Describes a single field in a protobuf message.
///
/// Dart type → [RpcFieldType] mapping:
/// - `String`   → [RpcFieldType.typeString]
/// - `int`      → [RpcFieldType.typeInt64]
/// - `double`   → [RpcFieldType.typeDouble]
/// - `bool`     → [RpcFieldType.typeBool]
/// - `List<T>`  → [RpcFieldLabel.repeated] + inner type
/// - Other class → [RpcFieldType.typeMessage] + [typeName]
class RpcFieldDescriptor {
  /// Proto field name (snake_case).
  final String name;

  /// Proto field number (must be unique within the message, starts at 1).
  final int number;

  /// Scalar type of the field.
  final RpcFieldType type;

  /// Field label: optional (default) or repeated.
  final RpcFieldLabel label;

  /// Fully-qualified type name for [RpcFieldType.typeMessage] fields,
  /// e.g. `'.mypackage.v1.MyMessage'`.
  final String? typeName;

  const RpcFieldDescriptor({
    required this.name,
    required this.number,
    required this.type,
    this.label = RpcFieldLabel.optional,
    this.typeName,
  });

  Uint8List toBytes() {
    final w = ProtoWriter();
    w.writeString(1, name);
    w.writeInt32(3, number);
    w.writeInt32(4, label.value);
    w.writeInt32(5, type.value);
    if (typeName != null) w.writeString(6, typeName!);
    w.writeString(10, _toJsonName(name));
    return w.toBytes();
  }

  // snake_case → camelCase for json_name field
  static String _toJsonName(String name) {
    return name.replaceAllMapped(
      RegExp(r'_([a-z])'),
      (m) => m.group(1)!.toUpperCase(),
    );
  }
}

/// Describes a protobuf message type with its fields.
class RpcMessageDescriptor {
  /// Message name (unqualified), e.g. `'EchoRequest'`.
  final String name;

  /// Fields of this message.
  final List<RpcFieldDescriptor> fields;

  const RpcMessageDescriptor({required this.name, required this.fields});

  Uint8List toBytes() {
    final w = ProtoWriter();
    w.writeString(1, name);
    for (final field in fields) {
      w.writeBytes(2, field.toBytes());
    }
    return w.toBytes();
  }
}

/// Describes a single RPC method.
class RpcMethodDescriptor {
  /// Method name, e.g. `'Echo'`.
  final String name;

  /// Fully-qualified input type, e.g. `'.mypackage.v1.EchoRequest'`.
  final String inputType;

  /// Fully-qualified output type, e.g. `'.mypackage.v1.EchoResponse'`.
  final String outputType;

  final bool clientStreaming;
  final bool serverStreaming;

  const RpcMethodDescriptor({
    required this.name,
    required this.inputType,
    required this.outputType,
    this.clientStreaming = false,
    this.serverStreaming = false,
  });

  Uint8List toBytes() {
    final w = ProtoWriter();
    w.writeString(1, name);
    w.writeString(2, inputType);
    w.writeString(3, outputType);
    if (clientStreaming) w.writeBool(5, true);
    if (serverStreaming) w.writeBool(6, true);
    return w.toBytes();
  }
}

/// Builds a `FileDescriptorProto` binary for use with [RpcReflectionRegistry].
///
/// Supports two usage patterns:
///
/// **Tier 1 — protobuf services**: pass raw descriptor bytes from `.pbjson.dart`:
/// ```dart
/// final descriptor = RpcFileDescriptorBuilder(
///   name: 'compat.proto',
///   package: 'compat.v1',
/// )
///   .addMessageBytes(echoRequestDescriptor)
///   .addMessageBytes(echoResponseDescriptor)
///   .addServiceBytes(echoServiceDescriptor)
///   .build();
///
/// registry.addFileDescriptor(descriptor);
/// ```
///
/// **Tier 2 — codegen native services**: generated code provides descriptor:
/// ```dart
/// registry.addFileDescriptor(EchoNames.grpcDescriptor);
/// ```
///
/// **Tier 3 — manual services (name-only)**:
/// ```dart
/// registry.addServiceName('myapp.v1.MyService');
/// ```
class RpcFileDescriptorBuilder {
  /// Filename used as the key in the reflection registry, e.g. `'echo.proto'`.
  final String name;

  /// Proto package, e.g. `'echo.v1'`.
  final String package;

  final List<Uint8List> _messageBytes = [];
  final List<Uint8List> _serviceBytes = [];

  RpcFileDescriptorBuilder({required this.name, required this.package});

  /// Adds a message descriptor from raw `DescriptorProto` bytes.
  ///
  /// Use bytes from `.pbjson.dart`, e.g. `echoRequestDescriptor`.
  RpcFileDescriptorBuilder addMessageBytes(Uint8List descriptorProtoBytes) {
    _messageBytes.add(descriptorProtoBytes);
    return this;
  }

  /// Adds a service descriptor from raw `ServiceDescriptorProto` bytes.
  ///
  /// Use bytes from `.pbjson.dart`, e.g. `echoServiceDescriptor`.
  RpcFileDescriptorBuilder addServiceBytes(
    Uint8List serviceDescriptorProtoBytes,
  ) {
    _serviceBytes.add(serviceDescriptorProtoBytes);
    return this;
  }

  /// Adds a message descriptor built from field-level metadata.
  ///
  /// Used by codegen for native rpc_dart (non-protobuf) services.
  RpcFileDescriptorBuilder addMessage(RpcMessageDescriptor message) {
    _messageBytes.add(message.toBytes());
    return this;
  }

  /// Adds a service descriptor built from method-level metadata.
  ///
  /// Used by codegen for native rpc_dart (non-protobuf) services.
  RpcFileDescriptorBuilder addService({
    required String name,
    required List<RpcMethodDescriptor> methods,
  }) {
    final w = ProtoWriter();
    w.writeString(1, name);
    for (final method in methods) {
      w.writeBytes(2, method.toBytes());
    }
    _serviceBytes.add(w.toBytes());
    return this;
  }

  /// Builds and returns the serialized `FileDescriptorProto` bytes.
  Uint8List build() {
    final w = ProtoWriter();
    w.writeString(1, name);
    w.writeString(2, package);
    for (final msg in _messageBytes) {
      w.writeBytes(4, msg); // field 4 = message_type
    }
    for (final svc in _serviceBytes) {
      w.writeBytes(6, svc); // field 6 = service
    }
    return w.toBytes();
  }
}
