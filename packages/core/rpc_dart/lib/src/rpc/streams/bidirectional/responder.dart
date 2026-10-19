// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

part of '../_index.dart';

/// Bidirectional stream responder: codecs → serialized; no codecs → zero-copy (zero-copy transport only). Handles incoming requests and sends responses independently.
///
/// With a [handler], the responder runs it once bound and relays its
/// responses, as the other responders do. Without one, the call is driven
/// through [requests] and [responseSink] or [send].
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
    Stream<TResponse> Function(Stream<TRequest> requests)? handler,
    super.context,
    super.logger,
  }) : _handler = handler,
       super(
         logName: 'BidirectionalResponder',
         className: 'BidirectionalStreamResponder',
       );

  /// Run once the responder is bound; null after that, or when driven by
  /// hand.
  Stream<TResponse> Function(Stream<TRequest> requests)? _handler;

  /// Incoming requests from the client; completes when the client closes its side.
  Stream<TRequest> get requests => _processor.requests;

  /// Convenience sink to send responses (forwards to send()).
  ///
  /// [SinkPump] owns the discipline; what is chosen here is [done] as the
  /// end-of-life signal. Without it a handler that ends the call itself — a
  /// trailer through [finishReceiving], an error through [sendError] — left its
  /// producer being drained into a finished stream, and silently: a send on a
  /// finished processor returns rather than throwing, so there was not even a
  /// log.
  StreamSink<TResponse> get responseSink =>
      (_responsePump ??= SinkPump<TResponse>(
        what: 'responseSink [id: $id]',
        // The processor directly, to avoid a cyclic dependency. A response
        // that could not go out ends the call here: finishing answers the
        // failure and completes [done], which stops the pump, so nothing
        // behind it reads as the stream continuing past a gap.
        send: (response) async {
          await _processor.send(response);
          if (_processor.isAnswered) await finishReceiving();
        },
        halfClose: finishReceiving,
        // END the call, the way ServerStreamResponder does when its handler
        // throws. `addStream` does NOT close the controller, so a source
        // that fails never reaches onDone: without this the client keeps
        // the payloads that did arrive and gets no ending at all --
        // measured as `2 payloads, NEVER ENDED`.
        onSourceFailed: (error, _) => unawaited(
          sendWireError(error, sendError).catchError((Object _) {}),
        ),
        ended: done,
        logger: _logger,
      )).sink;

  /// Drives [responseSink]; null until something asks for the sink.
  SinkPump<TResponse>? _responsePump;

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
      await _relay(handler(requests));
      await finishReceiving();
    } catch (error, stackTrace) {
      if (RpcStatus.isFaultError(error)) {
        _logger.error(
          'Error in bidi handler [id: $id]',
          error: error,
          stackTrace: stackTrace,
        );
      }
      await sendWireError(error, sendError);
    }
  }

  /// Whether the call has had, or is about to have, its last word; see
  /// `StreamProcessor.isAnswered`.
  bool get isAnswered => _processor.isAnswered;

  /// Sends a response to the client.
  Future<void> send(TResponse response) async {
    if (!_isActive) {
      _logger.warning(
        'Attempted to send response on inactive responder [id: $id]',
      );
      return;
    }

    await _processor.send(response);
  }

  /// Sends an error to the client.
  ///
  /// [statusDetailsBin] carries the encoded `google.rpc.Status` for an
  /// [RpcStatusException]'s structured `details`, as on the other shapes.
  ///
  /// [fault] false: the status answers the peer's own invalid input; see
  /// `StreamProcessor.sendError`.
  Future<void> sendError(
    int statusCode,
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

  @override
  Future<void> _stopHandler() async {
    // Cancels before closing and awaits neither: a handler's
    // `responseSink.addStream(source)` whose source is an `async*` suspended at
    // an `await` never completes its cancellation, and teardown must not hang
    // on it.
    _responsePump?.close();
  }
}
