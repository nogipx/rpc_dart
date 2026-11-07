// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'package:rpc_dart/rpc_dart.dart';

part 'contract.g.dart';

/// An opaque JSON-RPC message carried across an rpc_dart peer connection.
final class AcpRpcMessage implements IRpcSerializable {
  const AcpRpcMessage(this.value);

  final Map<String, dynamic> value;

  @override
  Map<String, dynamic> toJson() => value;

  factory AcpRpcMessage.fromJson(Map<String, dynamic> json) =>
      AcpRpcMessage(json);
}

@RpcService(name: 'AcpTunnel', kind: RpcServiceKind.peer)
abstract class IAcpTunnel {
  /// Full-duplex stream of decoded JSON-RPC messages.
  @RpcMethod.bidirectionalStream(name: 'exchange')
  Stream<AcpRpcMessage> exchange(
    Stream<AcpRpcMessage> messages, {
    RpcContext? context,
  });
}
