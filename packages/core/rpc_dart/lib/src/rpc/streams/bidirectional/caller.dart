// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

part of '../_index.dart';

/// Bidirectional stream caller: codecs → serialized; no codecs → zero-copy (zero-copy transport only). Sends and receives concurrently with no ordering restrictions.
final class BidirectionalStreamCaller<
  TRequest extends Object,
  TResponse extends Object
> {
  late final LogScope _logger;

  /// Stream processor.
  late final CallProcessor<TRequest, TResponse> _processor;

  /// Incoming responses from the server (payload or metadata); completes on
  /// end-of-stream, and surfaces a non-OK grpc-status trailer as an
  /// [RpcStatusException] error rather than completing silently.
  Stream<RpcMessage<TResponse>> get responses =>
      _processor.responses.transform(_grpcStatusErrorTransformer(_logger));

  /// Creates a bidirectional stream caller.
  BidirectionalStreamCaller({
    required IRpcTransport transport,
    required String serviceName,
    required String methodName,
    IRpcCodec<TRequest>? requestCodec,
    IRpcCodec<TResponse>? responseCodec,
    RpcContext? context,
    LogScope? logger,
  }) {
    final isZeroCopy = requestCodec == null && responseCodec == null;

    // Zero-copy requires transport support.
    if (isZeroCopy && !transport.supportsZeroCopy) {
      throw ArgumentError(
        'Zero-copy mode requires a transport with zero-copy support. '
        'Provide codecs for network transports.',
      );
    }

    // Serialization mode: codecs required.
    if (!isZeroCopy && (requestCodec == null || responseCodec == null)) {
      throw ArgumentError(
        'Codecs are required for serialization mode. '
        'For zero-copy leave codecs null.',
      );
    }

    _logger = logger?.child('BidirectionalCaller') ?? LogScope.noop;
    if (_logger.isInternal) {
      _logger.internal(
        'Creating ${isZeroCopy ? "Zero-copy" : "Serialized"} BidirectionalStreamCaller for $serviceName.$methodName',
      );
    }

    _processor = CallProcessor<TRequest, TResponse>(
      transport: transport,
      serviceName: serviceName,
      methodName: methodName,
      requestCodec: requestCodec,
      responseCodec: responseCodec,
      context: context,
      logger: _logger,
    );

    // Announce the call NOW, not on the first request.
    //
    // Bidirectional is the one shape whose caller may legitimately stay silent
    // indefinitely -- a subscription opens the channel and listens. Initial
    // metadata is otherwise sent by the first request or by the half-close, so
    // such a call never reached the responder at all: measured with a handler
    // that pushes five messages, the server reported openStreams=0,
    // activeResponders=0 and the caller hung. Sending zero messages AND
    // half-closing already worked; holding the request stream open did not.
    _processor._queueInitialMetadataIfUnsent();
  }

  /// Sends a request to the server (can be called multiple times).
  Future<void> send(TRequest request) async {
    if (_logger.isInternal) {
      _logger.internal('Sending request to bidirectional stream: $request');
    }
    await _processor.send(request);
  }

  /// Finishes sending requests; responses may continue until server completes.
  Future<void> finishSending() async {
    await _processor.finishSending();
  }

  /// Tells the server this call is being abandoned locally, so its handler
  /// stops waiting on a request stream that will never produce again.
  ///
  /// [finishSending] is the healthy counterpart: it half-closes and the
  /// handler's `await for` ends on its own. Abandoning is not half-closing, and
  /// the handler has to be able to tell them apart.
  ///
  /// [requestSink] calls this itself when its producer errors; a caller driving
  /// [send] by hand owns the same duty.
  ///
  /// Never throws.
  Future<void> abort(String reason) => _processor.notifyPeerOfAbort(reason);

  /// Response stream yielding payloads (zero-copy friendly).
  Stream<TResponse> get payloadResponses async* {
    await for (final response in responses) {
      if (response.payload != null) {
        if (_logger.isInternal) {
          _logger.internal('Received response in bidirectional stream');
        }
        yield response.payload!;
      }

      // Check status in metadata.
      if (response.metadata != null) {
        final status = RpcCallerTrailer.statusOf(response.metadata!);
        if (status != null && status != RpcStatus.ok) {
          final error = RpcCallerTrailer.errorOf(response.metadata!, status);
          _logger.error(
            'Bidirectional stream ended with error: $status - ${error.message}',
          );
          throw error;
        }
      }
    }
  }

  /// Drives [requestSink]; null until something asks for the sink.
  SinkPump<TRequest>? _requestPump;

  /// Sink used to send requests to the server.
  ///
  /// [SinkPump] owns the discipline; what is chosen here is
  /// [CallProcessor.done] as the end-of-life signal — every ending closes the
  /// response controller, and `isActive` does not, which is why a producer
  /// could not tell that its call had finished (round 390).
  StreamSink<TRequest> get requestSink => (_requestPump ??= SinkPump<TRequest>(
    what: 'requestSink',
    send: send,
    halfClose: finishSending,
    // Tell the peer and END the call, the way ClientStreamCaller does on the
    // same path. Without the notice the handler sits in `await for (requests)`
    // forever holding its stream state, responder and admission slot; without
    // the close the call stays half-alive and the peer keeps answering a stream
    // this side has already reset -- which on HTTP/2 destroys the whole
    // connection, every other call on it included. Half-closing instead of
    // aborting would be wrong either way: the handler would see a request
    // stream that ended successfully.
    onSourceFailed: (error, _) => unawaited(
      abort('request stream failed: $error').whenComplete(close).catchError((
        Object e,
        StackTrace st,
      ) {
        _logger.error(
          'Teardown after a failed request stream',
          error: e,
          stackTrace: st,
        );
      }),
    ),
    ended: _processor.done,
    logger: _logger,
  )).sink;

  /// Closes the stream and releases resources.
  Future<void> close() async {
    _logger.internal('Closing BidirectionalStreamCaller');
    // Cancel BEFORE closing the sink: `StreamController.close()` THROWS while
    // an `addStream` is still running, and that throw escapes this method
    // synchronously, leaving `_processor.close()` below unreachable.
    //
    // NOT awaited, for the reason ClientStreamCaller and ServerStreamResponder
    // both give: cancelling a stalled producer can block for ever. An `async*`
    // suspended at an `await` never completes its cancellation future, so
    // awaiting here traded the throw for a hang on the commonest bidi shape of
    // all -- a chat pumping an idle input stream. Dropping the await is safe
    // because `_recordCancel` clears the add-stream state SYNCHRONOUSLY, before
    // the future it returns.
    _requestPump?.close();
    await _processor.close();
  }
}
