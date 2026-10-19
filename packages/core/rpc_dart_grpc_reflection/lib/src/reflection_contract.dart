// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
// SPDX-License-Identifier: MIT

import 'package:rpc_dart/transport.dart';

import 'reflection_registry.dart';
import 'reflection_request_handler.dart';

/// gRPC Server Reflection contract for [RpcResponderEndpoint].
///
/// Register with both v1 and v1alpha to support all grpcurl versions:
/// ```dart
/// for (final c in ServerReflectionContract.both(registry)) {
///   endpoint.registerServiceContract(c);
/// }
/// ```
class ServerReflectionContract extends RpcResponderContract {
  final ReflectionRequestHandler _answer;

  ServerReflectionContract(
    RpcReflectionRegistry registry, {
    String serviceName = 'grpc.reflection.v1alpha.ServerReflection',
  }) : _answer = ReflectionRequestHandler(registry),
       super(serviceName) {
    addBidirectionalMethod<Uint8List, Uint8List>(
      methodName: 'ServerReflectionInfo',
      requestCodec: RpcBinaryCodec<Uint8List>(
        toBytes: (b) => b,
        fromBytes: Uint8List.fromList,
      ),
      responseCodec: RpcBinaryCodec<Uint8List>(
        toBytes: (b) => b,
        fromBytes: Uint8List.fromList,
      ),
      handler: _handleReflection,
    );
  }

  /// Returns contracts for both v1 and v1alpha reflection service names.
  static List<ServerReflectionContract> both(RpcReflectionRegistry registry) =>
      [
        ServerReflectionContract(
          registry,
          serviceName: 'grpc.reflection.v1.ServerReflection',
        ),
        ServerReflectionContract(
          registry,
          serviceName: 'grpc.reflection.v1alpha.ServerReflection',
        ),
      ];

  Stream<Uint8List> _handleReflection(
    Stream<Uint8List> requests, {
    RpcContext? context,
  }) async* {
    await for (final requestBytes in requests) {
      yield _answer(requestBytes);
    }
  }
}
