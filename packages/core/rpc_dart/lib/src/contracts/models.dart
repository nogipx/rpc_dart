// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

part of '_index.dart';

/// Data transfer modes in RPC contracts.
enum RpcDataTransferMode {
  /// Zero-copy mode — direct object passing without serialization.
  /// Works only with InMemoryTransport.
  zeroCopy,

  /// Codec mode — serialization via IRpcCodec.
  /// Works with any transport.
  codec,

  /// Auto mode — picks based on codec presence (codecs → codec mode, otherwise
  /// zeroCopy).
  auto,
}

/// RPC method types.
enum RpcMethodType {
  /// Single request, single response.
  unaryRequest,

  /// Single request, stream of responses.
  serverStream,

  /// Stream of requests, single response.
  clientStream,

  /// Stream of requests and responses.
  bidirectionalStream,
}

/// Method registration within a contract.
final class RpcMethodRegistration<
  TRequest extends IRpcSerializable,
  TResponse extends IRpcSerializable
> {
  /// Method identifier used for routing.
  final String name;

  /// Communication pattern for this method.
  final RpcMethodType type;

  /// User-provided handler function.
  final Function handler;

  /// Human-readable description of the method.
  final String description;

  /// Codec used to serialize/deserialize requests.
  final IRpcCodec<TRequest> requestCodec;

  /// Codec used to serialize/deserialize responses.
  final IRpcCodec<TResponse> responseCodec;

  /// Creates a method registration entry.
  const RpcMethodRegistration({
    required this.name,
    required this.type,
    required this.handler,
    required this.description,
    required this.requestCodec,
    required this.responseCodec,
  });

  /// Type-safe unary handler invocation with context.
  Future<TResponse> callUnaryHandler(
    RpcContext context,
    TRequest request,
  ) async {
    final typedHandler =
        handler as Future<TResponse> Function(TRequest, {RpcContext? context});
    return await typedHandler(request, context: context);
  }

  /// Type-safe server-stream handler invocation with context.
  Stream<TResponse> callServerStreamHandler(
    RpcContext context,
    TRequest request,
  ) {
    final typedHandler =
        handler as Stream<TResponse> Function(TRequest, {RpcContext? context});
    return typedHandler(request, context: context);
  }

  /// Type-safe client-stream handler invocation with context.
  Future<TResponse> callClientStreamHandler(
    RpcContext context,
    Stream<TRequest> requests,
  ) async {
    final typedHandler =
        handler
            as Future<TResponse> Function(
              Stream<TRequest>, {
              RpcContext? context,
            });
    return await typedHandler(requests, context: context);
  }

  /// Type-safe bidirectional-stream handler invocation with context.
  Stream<TResponse> callBidirectionalStreamHandler(
    RpcContext context,
    Stream<TRequest> requests,
  ) {
    final typedHandler =
        handler
            as Stream<TResponse> Function(
              Stream<TRequest>, {
              RpcContext? context,
            });
    return typedHandler(requests, context: context);
  }

  /// Safely casts the incoming request stream.
  Stream<TRequest> castRequestStream(Stream<IRpcSerializable> stream) {
    return stream.cast<TRequest>();
  }

  /// Safely casts the response to the base type.
  IRpcSerializable castResponse(TResponse response) {
    return response as IRpcSerializable;
  }
}

/// Zero-copy method registration without [IRpcSerializable] bounds.
final class RpcZeroCopyMethodRegistration<
  TRequest extends Object,
  TResponse extends Object
> {
  /// Method identifier used for routing.
  final String name;

  /// Communication pattern for this method.
  final RpcMethodType type;

  /// User-provided handler function.
  final Function handler;

  /// Human-readable description of the method.
  final String description;

  /// Creates a zero-copy method registration entry.
  const RpcZeroCopyMethodRegistration({
    required this.name,
    required this.type,
    required this.handler,
    required this.description,
  });

  /// Type-safe unary handler invocation with context.
  Future<TResponse> callUnaryHandler(
    RpcContext context,
    TRequest request,
  ) async {
    final typedHandler =
        handler as Future<TResponse> Function(TRequest, {RpcContext? context});
    return await typedHandler(request, context: context);
  }

  /// Type-safe server-stream handler invocation with context.
  Stream<TResponse> callServerStreamHandler(
    RpcContext context,
    TRequest request,
  ) {
    final typedHandler =
        handler as Stream<TResponse> Function(TRequest, {RpcContext? context});
    return typedHandler(request, context: context);
  }

  /// Type-safe client-stream handler invocation with context.
  Future<TResponse> callClientStreamHandler(
    RpcContext context,
    Stream<TRequest> requests,
  ) async {
    final typedHandler =
        handler
            as Future<TResponse> Function(
              Stream<TRequest>, {
              RpcContext? context,
            });
    return await typedHandler(requests, context: context);
  }

  /// Type-safe bidirectional-stream handler invocation with context.
  Stream<TResponse> callBidirectionalStreamHandler(
    RpcContext context,
    Stream<TRequest> requests,
  ) {
    final typedHandler =
        handler
            as Stream<TResponse> Function(
              Stream<TRequest>, {
              RpcContext? context,
            });
    return typedHandler(requests, context: context);
  }
}
