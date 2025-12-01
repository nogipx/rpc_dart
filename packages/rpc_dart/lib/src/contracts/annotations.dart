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
