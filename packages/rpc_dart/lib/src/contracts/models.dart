// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
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
  unaryRequest,
  serverStream,
  clientStream,
  bidirectionalStream,
}

/// Method registration within a contract.
final class RpcMethodRegistration<TRequest extends IRpcSerializable,
    TResponse extends IRpcSerializable> {
  final String name;
  final RpcMethodType type;
  final Function handler;
  final String description;
  final IRpcCodec<TRequest> requestCodec;
  final IRpcCodec<TResponse> responseCodec;

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
    final typedHandler = handler as Future<TResponse> Function(
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
    final typedHandler = handler as Stream<TResponse> Function(
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

/// 🚀 ZERO-COPY: Method registration without IRpcSerializable bounds.
final class RpcZeroCopyMethodRegistration<TRequest extends Object,
    TResponse extends Object> {
  final String name;
  final RpcMethodType type;
  final Function handler;
  final String description;

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
    final typedHandler = handler as Future<TResponse> Function(
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
    final typedHandler = handler as Stream<TResponse> Function(
      Stream<TRequest>, {
      RpcContext? context,
    });
    return typedHandler(requests, context: context);
  }
}
