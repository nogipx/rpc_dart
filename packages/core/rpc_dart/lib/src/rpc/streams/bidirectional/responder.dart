// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

part of '../_index.dart';

/// Bidirectional stream responder: codecs → serialized; no codecs → zero-copy (zero-copy transport only). Handles incoming requests and sends responses independently.
///
/// Runs its [handler] once bound and relays its responses, as the other
/// responders do.
final class BidirectionalStreamResponder<
  TRequest extends Object,
  TResponse extends Object
>
    extends RpcResponderBase<TRequest, TResponse> {
  /// Creates a bidirectional stream responder.
  BidirectionalStreamResponder({
    required super.id,
    required super.transport,
    required super.serviceName,
    required super.methodName,
    super.requestCodec,
    super.responseCodec,
    required Stream<TResponse> Function(Stream<TRequest> requests) handler,
    super.context,
    super.logger,
    super.compressResponses,
  }) : _handler = handler,
       super(
         logName: 'BidirectionalResponder',
         className: 'BidirectionalStreamResponder',
       );

  /// Run once the responder is bound; null after that.
  Stream<TResponse> Function(Stream<TRequest> requests)? _handler;

  @override
  void bindToMessageStream(Stream<RpcTransportMessage> messageStream) {
    super.bindToMessageStream(messageStream);
    final handler = _handler;
    _handler = null;
    if (handler != null) unawaited(_serve(handler));
  }

  /// Runs [handler] on the requests, relays its responses and finishes the
  /// call; a handler failure answers it instead.
  Future<void> _serve(
    Stream<TResponse> Function(Stream<TRequest> requests) handler,
  ) async {
    try {
      await _relay(handler(_processor.requests));
      await finishReceiving();
    } catch (error, stackTrace) {
      if (isFaultError(error)) {
        _logger.error(
          'Error in bidi handler [id: $id]',
          error: error,
          stackTrace: stackTrace,
        );
      }
      await sendWireError(error, sendError);
    }
  }

  /// Sends an error to the client.
  ///
  /// [statusDetailsBin] carries the encoded `google.rpc.Status` for an
  /// [RpcStatusException]'s structured `details`, as on the other shapes.
  ///
  /// [fault] false: the status answers the peer's own invalid input; see
  /// `StreamProcessor.sendError`.
  Future<void> sendError(
    RpcStatus statusCode,
    String message, {
    Uint8List? statusDetailsBin,
    bool fault = true,
  }) async {
    if (!_isActive) return;

    try {
      await _processor.sendError(
        statusCode,
        message,
        statusDetailsBin: statusDetailsBin,
        fault: fault,
      );
    } finally {
      _completeDone();
    }
  }

  /// Finishes sending responses; call when server has no more responses.
  Future<void> finishReceiving() async {
    if (!_isActive) return;

    try {
      await _processor.finishSending();
    } finally {
      _completeDone();
    }
  }
}
