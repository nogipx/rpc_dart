// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

library;

/// Pins the protobuf field number for a model field in a generated
/// gRPC `FileDescriptorProto` (only relevant when the service uses
/// `@RpcService(grpcDescriptor: true)`).
///
/// Proto wire compatibility depends on stable field numbers. Without this
/// annotation the generator falls back to declaration order, so reordering,
/// inserting, or removing a Dart field silently renumbers the proto fields and
/// breaks the wire format. Annotate fields to make numbering explicit and
/// stable:
///
/// ```dart
/// class Ping implements IRpcSerializable {
///   @RpcProtoField(1)
///   final String id;
///   @RpcProtoField(2)
///   final int seq;
///   const Ping({required this.id, required this.seq});
///   @override
///   Map<String, dynamic> toJson() => {'id': id, 'seq': seq};
/// }
/// ```
class RpcProtoField {
  /// Creates an annotation pinning the proto field [number] (1-based, unique
  /// within the message).
  const RpcProtoField(this.number);

  /// Proto field number (must be >= 1 and unique within the message).
  final int number;
}
