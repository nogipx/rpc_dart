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

  /// Auto mode, the default.
  ///
  /// A UNARY call passes objects by reference whenever the transport supports
  /// it (in-memory, isolate), codecs given or not: the codecs are not called
  /// and `maxMessageLengthBytes` does not apply, because there are no bytes.
  /// Elsewhere, and on every streaming shape that has codecs, it serializes.
  /// Use [codec] to serialize everywhere.
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

/// One method of a contract: its name, shape and handler, and the codecs it
/// serializes with. No codecs is zero-copy: objects pass by reference.
///
/// Held as `RpcMethodRegistration<Object, Object>` by the endpoint, so the
/// `call*` methods take untyped requests and give them to the handler as the
/// types it was registered with.
final class RpcMethodRegistration<
  TRequest extends Object,
  TResponse extends Object
> {
  /// Method identifier used for routing.
  final String name;

  /// Communication pattern for this method.
  final RpcMethodType type;

  /// User-provided handler function, of the shape [type] names.
  final Function handler;

  /// Human-readable description of the method.
  final String description;

  /// Codec for requests; null with [responseCodec] for zero-copy.
  final IRpcCodec<TRequest>? requestCodec;

  /// Codec for responses; null with [requestCodec] for zero-copy.
  final IRpcCodec<TResponse>? responseCodec;

  /// Creates a method registration entry.
  const RpcMethodRegistration({
    required this.name,
    required this.type,
    required this.handler,
    required this.description,
    this.requestCodec,
    this.responseCodec,
  });

  /// Whether the method passes objects instead of serializing them.
  bool get isZeroCopy => requestCodec == null && responseCodec == null;

  /// Runs a unary handler on [request].
  Future<TResponse> callUnaryHandler(RpcContext context, Object request) async {
    final typedHandler =
        handler as Future<TResponse> Function(TRequest, {RpcContext? context});
    return typedHandler(request as TRequest, context: context);
  }

  /// Runs a server-stream handler on [request].
  Stream<TResponse> callServerStreamHandler(
    RpcContext context,
    Object request,
  ) {
    final typedHandler =
        handler as Stream<TResponse> Function(TRequest, {RpcContext? context});
    return typedHandler(request as TRequest, context: context);
  }

  /// Runs a client-stream handler on [requests].
  Future<TResponse> callClientStreamHandler(
    RpcContext context,
    Stream<Object> requests,
  ) async {
    final typedHandler =
        handler
            as Future<TResponse> Function(
              Stream<TRequest>, {
              RpcContext? context,
            });
    return typedHandler(requests.cast<TRequest>(), context: context);
  }

  /// Runs a bidirectional-stream handler on [requests].
  Stream<TResponse> callBidirectionalStreamHandler(
    RpcContext context,
    Stream<Object> requests,
  ) {
    final typedHandler =
        handler
            as Stream<TResponse> Function(
              Stream<TRequest>, {
              RpcContext? context,
            });
    return typedHandler(requests.cast<TRequest>(), context: context);
  }
}
