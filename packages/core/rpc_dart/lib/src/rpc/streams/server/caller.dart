// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

part of '../_index.dart';

/// Server-stream caller: codecs → serialized; no codecs → zero-copy (zero-copy transport only). Sends one request, receives a response stream.
final class ServerStreamCaller<
  TRequest extends Object,
  TResponse extends Object
> {
  late final LogScope _logger;

  /// Stream processor.
  late final CallProcessor<TRequest, TResponse> _processor;

  /// Ensures only one request is sent.
  bool _requestSent = false;

  /// Creates a server-stream caller.
  ServerStreamCaller({
    required IRpcTransport transport,
    required String serviceName,
    required String methodName,
    IRpcCodec<TRequest>? requestCodec,
    IRpcCodec<TResponse>? responseCodec,
    RpcContext? context,
    LogScope? logger,
  }) {
    final isZeroCopy = requestCodec == null && responseCodec == null;

    // Zero-copy mode: requires in-memory transport.
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

    _logger = logger?.child('ServerCaller') ?? LogScope.noop;
    if (_logger.isInternal) {
      _logger.internal(
        'Creating ${isZeroCopy ? "Zero-copy" : "Serialized"} ServerStreamCaller for $serviceName.$methodName',
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
  }

  /// Response stream (completes when server finishes or on error).
  ///
  /// Forwards processor messages, but a non-OK grpc-status trailer surfaces as
  /// an [RpcStatusException] error on the stream instead of completing silently.
  Stream<RpcMessage<TResponse>> get responses =>
      _processor.responses.transform(_grpcStatusErrorTransformer(_logger));

  /// Sends the single request; may be called only once.
  Future<void> send(TRequest request) async {
    if (_requestSent) {
      throw RpcStatusException(
        RpcStatus.failedPrecondition,
        'ServerStream allows only one request; it was already sent.',
      );
    }

    if (_logger.isInternal) {
      _logger.internal('Sending single request to server stream: $request');
    }

    try {
      _requestSent = true; // Set flag immediately to block duplicates.

      // Send the request via processor.
      await _processor.send(request);
      _logger.internal('Request sent via CallProcessor');

      // Finish sending to signal only one request (server-stream semantics).
      await _processor.finishSending();
    } catch (e, stackTrace) {
      _logger.error(
        'Failed to send request to server stream',
        error: e,
        stackTrace: stackTrace,
      );
      rethrow;
    }
  }

  /// Convenience helper to send a request and yield responses.
  Stream<TResponse> call(TRequest request) async* {
    try {
      // Send request.
      await send(request);

      // ONE record where the call actually begins. "Executing server stream
      // call" and "Request sent, awaiting response stream" bracketed a single
      // await and said the same thing twice; the per-response line below said
      // it again for every payload.
      if (_logger.isInternal) {
        _logger.internal('Server stream call sent, awaiting responses');
      }

      // Process response stream.
      await for (final response in responses) {
        if (response.payload != null) {
          yield response.payload!;
        }

        // Inspect status in metadata.
        if (response.metadata != null) {
          final status = RpcCallerTrailer.statusOf(response.metadata!);
          if (status != null && status != RpcStatus.ok) {
            final error = RpcCallerTrailer.errorOf(response.metadata!, status);
            _logger.error(
              'Server stream ended with error: $status - ${error.message}',
            );
            throw error;
          }
        }
      }

      _logger.internal('Server stream completed');
    } catch (e) {
      _logger.error('Server stream call failed', error: e);
      rethrow;
    } finally {
      await close();
    }
  }

  /// Closes the caller and releases resources.
  Future<void> close() async {
    _logger.internal('Closing ServerStreamCaller');
    await _processor.close();
  }
}

/// Builds a transformer that forwards every [RpcMessage] but, when a message
/// carries a non-OK grpc-status trailer, surfaces an [RpcStatusException] error
/// on the stream instead of letting it complete silently.
///
/// Implemented with [StreamTransformer.fromHandlers] (not an `async*` wrapper)
/// to preserve correct pause/resume/cancel semantics over the single-
/// subscription processor stream — an `async*` blocked in `await for` can
/// deadlock when a downstream `take(n)` cancels mid-stream.
StreamTransformer<RpcMessage<T>, RpcMessage<T>>
_grpcStatusErrorTransformer<T extends Object>(LogScope logger) {
  return StreamTransformer<RpcMessage<T>, RpcMessage<T>>.fromHandlers(
    handleData: (response, sink) {
      sink.add(response);

      final metadata = response.metadata;
      if (metadata == null) return;
      final status = RpcCallerTrailer.statusOf(metadata);
      if (status == null || status == RpcStatus.ok) return;

      final error = RpcCallerTrailer.errorOf(metadata, status);
      if (logger.isInternal) {
        logger.internal(
          'Raw responses saw error trailer: $status - ${error.message}',
        );
      }
      sink.addError(error);
    },
  );
}
