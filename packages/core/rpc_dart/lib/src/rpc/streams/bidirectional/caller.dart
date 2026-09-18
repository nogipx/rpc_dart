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
        final statusStr = response.metadata!.getHeaderValue(
          RpcHeaders.grpcStatus,
        );
        if (statusStr != null) {
          final status = int.tryParse(statusStr) ?? RpcStatus.unknown;
          if (status != RpcStatus.ok) {
            final message =
                response.metadata!.getHeaderValue(RpcHeaders.grpcMessage) ??
                'Unknown error';
            final decodedMessage = RpcMetadata.decodeGrpcMessage(message);
            _logger.error(
              'Bidirectional stream ended with error: $status - $decodedMessage',
            );
            throw RpcStatusException.fromTrailer(
              status,
              decodedMessage,
              detailsBin: response.metadata!.statusDetailsBin,
            );
          }
        }
      }
    }
  }

  /// Request sink for sending to the server (zero-copy friendly).
  StreamSink<TRequest>? _requestSink;

  /// Sink used to send requests to the server.
  StreamSink<TRequest> get requestSink {
    if (_requestSink == null) {
      final controller = StreamController<TRequest>();
      var finished = false;
      var aborted = false;
      late final StreamSubscription<TRequest> sub;
      sub = controller.stream.listen(
        // Pausing for the duration of each send is what bounds the producer:
        // `addStream` stops pulling while this subscription is paused, so the
        // caller holds one message instead of however many the producer can
        // offer. Without it _sendSequence is an unbounded queue in front of the
        // transport -- the same bound ClientStreamCaller.call() keeps.
        //
        // Not awaited, and the failure is caught rather than raised: a throw
        // from a listen callback has nothing awaiting it and would reach the
        // zone, which is exit 255 in a server process. `send` throws by design
        // once the call is no longer active, and the consumer already has the
        // real cause on `responses`.
        (request) {
          if (_logger.isInternal) {
            _logger.internal(
              'Sending request in bidirectional stream: $request',
            );
          }
          sub.pause();
          unawaited(
            send(request)
                .catchError((Object e, StackTrace stackTrace) {
                  _logger.error(
                    'Failed to send request via requestSink',
                    error: e,
                    stackTrace: stackTrace,
                  );
                })
                .whenComplete(() {
                  if (!finished) sub.resume();
                }),
          );
        },
        onDone: () async {
          finished = true;
          _logger.internal('Request stream completed');
          try {
            await finishSending();
          } catch (e, stackTrace) {
            _logger.error(
              'Failed to half-close via requestSink',
              error: e,
              stackTrace: stackTrace,
            );
          }
        },
        // Tell the peer and END the call, the way ClientStreamCaller does on
        // the same path. Without the notice the handler sits in `await for
        // (requests)` forever holding its stream state, responder and admission
        // slot; without the close the call stays half-alive and the peer keeps
        // answering a stream this side has already reset -- which on HTTP/2
        // destroys the whole connection, every other call on it included.
        // Half-closing instead of aborting would be wrong either way: the
        // handler would see a request stream that ended successfully.
        onError: (Object error, StackTrace stackTrace) {
          _logger.error(
            'Error in request stream',
            error: error,
            stackTrace: stackTrace,
          );
          if (aborted || finished) return;
          aborted = true;
          unawaited(abort('request stream failed: $error').whenComplete(close));
        },
      );
      _requestSink = controller.sink;
    }
    return _requestSink!;
  }

  /// Closes the stream and releases resources.
  Future<void> close() async {
    _logger.internal('Closing BidirectionalStreamCaller');
    if (_requestSink != null) {
      unawaited(_requestSink!.close());
    }
    await _processor.close();
  }
}
