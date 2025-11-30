import 'package:rpc_dart/rpc_dart.dart' show RpcDataTransferMode;

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
    this.kind = RpcMethodKind.unary,
    this.description,
    this.requestCodec,
    this.responseCodec,
    this.transferMode,
  });

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
