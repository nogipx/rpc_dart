// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

part of '_index.dart';

/// RPC method kinds supported by the generator.
enum RpcMethodKind { unary, serverStream, clientStream, bidirectionalStream }

/// Marks a service interface to generate caller/responder wrappers.
class RpcService {
  const RpcService({
    required this.name,
    this.transferMode = RpcDataTransferMode.auto,
    this.description,
  });

  /// Contract/service name.
  final String name;

  /// Default data transfer mode for the generated contracts.
  final RpcDataTransferMode transferMode;

  /// Optional docs that will be copied into generated code.
  final String? description;
}

/// Marks an inherited RPC method as removed in this contract version.
///
/// The generator produces a `@Deprecated` + `throw UnsupportedError`
/// implementation so callers get a compile-time warning and a clear
/// runtime error if the method is still invoked.
///
/// Usage:
/// ```dart
/// @RpcService(name: 'MyService.v4')
/// abstract class IMyServiceV4 implements IMyServiceV3 {
///   @RpcRemoved('Use newMethod() instead')
///   @override
///   Future<OldResponse> oldMethod(OldRequest request, {RpcContext? context});
/// }
/// ```
class RpcRemoved {
  const RpcRemoved([this.message = 'This method has been removed.']);
  final String message;
}

/// Describes how a method should be registered and invoked.
class RpcMethod {
  const RpcMethod({
    required this.name,
    required this.kind,
    this.description,
    this.requestCodec,
    this.responseCodec,
    this.transferMode,
  });

  const RpcMethod.unary({
    required this.name,
    this.description,
    this.requestCodec,
    this.responseCodec,
    this.transferMode,
  }) : kind = RpcMethodKind.unary;

  const RpcMethod.serverStream({
    required this.name,
    this.description,
    this.requestCodec,
    this.responseCodec,
    this.transferMode,
  }) : kind = RpcMethodKind.serverStream;

  const RpcMethod.clientStream({
    required this.name,
    this.description,
    this.requestCodec,
    this.responseCodec,
    this.transferMode,
  }) : kind = RpcMethodKind.clientStream;

  const RpcMethod.bidirectionalStream({
    required this.name,
    this.description,
    this.requestCodec,
    this.responseCodec,
    this.transferMode,
  }) : kind = RpcMethodKind.bidirectionalStream;

  /// RPC method identifier used for registration.
  final String name;

  /// RPC kind (unary, streams, bidi).
  final RpcMethodKind kind;

  /// Optional docs that will be copied into generated code.
  final String? description;

  /// Override request codec (must have a const constructor).
  final Type? requestCodec;

  /// Override response codec (must have a const constructor).
  final Type? responseCodec;

  /// Optional transfer mode override for this method.
  final RpcDataTransferMode? transferMode;
}
