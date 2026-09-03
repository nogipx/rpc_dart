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
    _logger.internal(
      'Creating ${isZeroCopy ? "Zero-copy" : "Serialized"} BidirectionalStreamCaller for $serviceName.$methodName',
    );

    _processor = CallProcessor<TRequest, TResponse>(
      transport: transport,
      serviceName: serviceName,
      methodName: methodName,
      requestCodec: requestCodec,
      responseCodec: responseCodec,
      context: context,
      logger: _logger,
    );
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
  /// [finishSending] is the healthy counterpart: it half-closes, and the
  /// handler's `await for` ends on its own. A request stream that ERRORS has no
  /// such signal, and the bridge's cancellation-token notice is only wired to
  /// consumer cancellation -- so that path told the server nothing and parked
  /// its handler for good.
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
      controller.stream.listen(
        (request) async {
          if (_logger.isInternal) {
            _logger.internal(
              'Sending request in bidirectional stream: $request',
            );
          }
          await send(request);
        },
        onDone: () async {
          _logger.internal('Request stream completed');
          await finishSending();
        },
        onError: (error, stackTrace) {
          _logger.error(
            'Error in request stream',
            error: error,
            stackTrace: stackTrace,
          );
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
      _requestSink!.close(); // Do not await completion.
    }
    await _processor.close();
  }
}
