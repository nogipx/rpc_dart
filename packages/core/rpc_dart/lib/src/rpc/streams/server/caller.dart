// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

part of '../_index.dart';

/// Server-stream caller: codecs → serialized; no codecs → zero-copy (zero-copy transport only). Sends one request, receives a response stream.
final class ServerStreamCaller<TRequest extends Object,
    TResponse extends Object> {
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
    _logger.internal(
      'Creating ${isZeroCopy ? "Zero-copy" : "Serialized"} ServerStreamCaller for $serviceName.$methodName',
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

  /// Response stream (completes when server finishes or on error).
  Stream<RpcMessage<TResponse>> get responses => _processor.responses;

  /// Sends the single request; may be called only once.
  Future<void> send(TRequest request) async {
    if (_requestSent) {
      throw StateError(
        'ServerStream allows only one request; it was already sent.',
      );
    }

    _logger.internal(
      'Sending single request to server stream: $request',
    );

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
    _logger.internal('Executing server stream call');

    try {
      // Send request.
      await send(request);

      _logger.internal('Request sent, awaiting response stream');

      // Process response stream.
      await for (final response in responses) {
        if (response.payload != null) {
          _logger.internal('Received response from server');
          yield response.payload!;
        }

        // Inspect status in metadata.
        if (response.metadata != null) {
          final statusStr = response.metadata!.getHeaderValue(
            RpcHeaders.grpcStatus,
          );
          if (statusStr != null) {
            final status = int.tryParse(statusStr) ?? RpcStatus.unknown;
            if (status != RpcStatus.ok) {
              final message = response.metadata!.getHeaderValue(
                    RpcHeaders.grpcMessage,
                  ) ??
                  'Unknown error';
              final decodedMessage = RpcMetadata.decodeGrpcMessage(message);
              _logger.error(
                'Server stream ended with error: $status - $decodedMessage',
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

      _logger.internal('Server stream completed');
    } catch (e) {
      _logger.error('Server stream call failed', error: e);
      if (e is! RpcCancelledException) rethrow;
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
