// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

part of '../_index.dart';

/// Unary responder: codecs → serialized; no codecs → zero-copy (zero-copy
/// transport only). Handles one request and answers one response.
///
/// A server stream of one response: [ServerStreamResponder] holds the request
/// until the request stream ends, refuses a second one INTERNAL, answers a
/// call that carried none INVALID_ARGUMENT, and puts the response, its error
/// or the OK trailer on the wire.
final class UnaryResponder<TRequest extends Object, TResponse extends Object>
    implements IRpcResponder {
  /// Creates a unary responder for stream [id].
  UnaryResponder({
    required int id,
    required IRpcTransport transport,
    required String serviceName,
    required String methodName,
    IRpcCodec<TRequest>? requestCodec,
    IRpcCodec<TResponse>? responseCodec,
    required FutureOr<TResponse> Function(TRequest request) handler,
    RpcContext? context,
    LogScope? logger,
  }) : this._(
         id: id,
         transport: transport,
         serviceName: serviceName,
         methodName: methodName,
         requestCodec: requestCodec,
         responseCodec: responseCodec,
         handler: handler,
         context: context,
         logger: logger?.child('Unary') ?? LogScope.noop,
       );

  UnaryResponder._({
    required this.id,
    required IRpcTransport transport,
    required String serviceName,
    required String methodName,
    required IRpcCodec<TRequest>? requestCodec,
    required IRpcCodec<TResponse>? responseCodec,
    required FutureOr<TResponse> Function(TRequest request) handler,
    required RpcContext? context,
    required LogScope logger,
  }) : _responder = ServerStreamResponder<TRequest, TResponse>._single(
         id: id,
         transport: transport,
         serviceName: serviceName,
         methodName: methodName,
         requestCodec: requestCodec,
         responseCodec: responseCodec,
         handler: (request) async {
           final response = await handler(request);
           if (logger.isInternal) {
             logger.internal('Served /$serviceName/$methodName [id: $id]');
           }
           return response;
         },
         context: context,
         logger: logger,
       );

  final ServerStreamResponder<TRequest, TResponse> _responder;

  @override
  final int id;

  @override
  Future<void> get done => _responder.done;

  @override
  void bindToMessageStream(Stream<RpcTransportMessage> messageStream) =>
      _responder.bindToMessageStream(messageStream);

  @override
  Future<void> close() => _responder.close();
}
