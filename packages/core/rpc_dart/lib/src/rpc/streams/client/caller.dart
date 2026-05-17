// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

part of '../_index.dart';

/// Client streaming caller: codecs → serialized; no codecs → zero-copy (zero-copy transport only). Sends many requests, receives one response.
final class ClientStreamCaller<TRequest extends Object,
    TResponse extends Object> {
  late final LogScope _logger;

  /// Stream processor.
  late final CallProcessor<TRequest, TResponse> _processor;

  /// Completer with the response.
  final Completer<TResponse> _responseCompleter = Completer<TResponse>();

  /// Subscription to responses.
  StreamSubscription? _subscription;

  /// Marks send completion.
  bool _sendingFinished = false;

  /// Creates a client-stream caller.
  ClientStreamCaller({
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

    _logger = logger?.child('ClientCaller') ?? LogScope.noop;
    _logger.internal(
      'Creating ${isZeroCopy ? "Zero-copy" : "Serialized"} ClientStreamCaller for $serviceName.$methodName',
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

    _setupResponseHandler();
  }

  /// Configures response handler.
  void _setupResponseHandler() {
    _subscription = _processor.responses.listen(
      (rpcMessage) {
        _logger.internal(
          'Received response from server: isMetadataOnly=${rpcMessage.isMetadataOnly}, isEndOfStream=${rpcMessage.isEndOfStream}',
        );

        // Check for errors in metadata/trailers.
        if (rpcMessage.isMetadataOnly && rpcMessage.metadata != null) {
          final statusCode = rpcMessage.metadata!.getHeaderValue(
            RpcHeaders.grpcStatus,
          );
          _logger.internal('Status code from metadata: $statusCode');

          if (statusCode != null && statusCode != '0') {
            final errorMessage = rpcMessage.metadata!.getHeaderValue(
                  RpcHeaders.grpcMessage,
                ) ??
                '';
            final decodedMessage = RpcMetadata.decodeGrpcMessage(errorMessage);
            _logger.error(
              'Received error status code: $statusCode - $decodedMessage',
            );

            if (!_responseCompleter.isCompleted) {
              _responseCompleter.completeError(
                RpcStatusException.fromTrailer(
                  int.tryParse(statusCode) ?? RpcStatus.unknown,
                  decodedMessage,
                  detailsBin: rpcMessage.metadata!.statusDetailsBin,
                ),
              );
            }
            return;
          }

          // If final status OK (0) but no payload, fail because data was expected.
          if (statusCode == '0' &&
              rpcMessage.isEndOfStream &&
              !_responseCompleter.isCompleted) {
            _logger.warning('Status OK but no response payload');
            _responseCompleter.completeError(
              Exception('Stream closed without response payload'),
            );
          }
        }

        // Handle responses with payload.
        if (!rpcMessage.isMetadataOnly &&
            !_responseCompleter.isCompleted &&
            rpcMessage.payload != null) {
          _logger.internal(
            'Received payload: ${rpcMessage.payload}',
          );
          _responseCompleter.complete(rpcMessage.payload!);
        }
      },
      onError: (error, stackTrace) {
        _logger.error(
          'Error in response stream',
          error: error,
          stackTrace: stackTrace,
        );
        if (!_responseCompleter.isCompleted) {
          _responseCompleter.completeError(error, stackTrace);
        }
      },
      onDone: () {
        _logger.internal('Response stream completed');
        if (!_responseCompleter.isCompleted) {
          // Might be transport close; surface error if still pending.
          try {
            _responseCompleter.completeError(
              Exception('Stream closed without receiving response'),
            );
          } catch (e) {
            // If completer already finished, ignore.
            _logger.internal('Completer already completed, skipping error: $e');
          }
        }
      },
    );
  }

  /// Sends a request into the stream. Safe to call multiple times until finishSending().
  Future<void> send(TRequest request) async {
    if (_sendingFinished) {
      throw StateError(
        'Sending already completed. Call finishSending() to get the response.',
      );
    }

    _logger.internal('Sending request to client stream: $request');
    await _processor.send(request);
  }

  /// Completes sending requests and waits for a single response.
  ///
  /// Returns the single server response; times out after 30s.
  Future<TResponse> finishSending() async {
    if (_sendingFinished) {
      throw StateError('Sending was already completed earlier.');
    }

    _sendingFinished = true;

    try {
      // Finish sending requests.
      await _processor.finishSending();
      _logger.internal('Send complete, waiting for response');

      // Await single response with timeout.
      return await _responseCompleter.future.timeout(
        Duration(seconds: 30),
        onTimeout: () {
          _logger.error('Response wait timed out');
          // Free resources on timeout.
          unawaited(close());
          throw TimeoutException(
            'Response wait timeout from server',
            Duration(seconds: 30),
          );
        },
      );
    } catch (e, stackTrace) {
      _logger.error(
        'Failed to finish sending',
        error: e,
        stackTrace: stackTrace,
      );

      if (!_responseCompleter.isCompleted) {
        _responseCompleter.completeError(e, stackTrace);
      }

      // Free resources and close transport.
      unawaited(close());
      rethrow;
    }
  }

  /// Convenience: send a request stream and return the single response (auto-closes).
  Future<TResponse> call(Stream<TRequest> requests) async {
    _logger.internal('Executing client stream call');

    try {
      // Send the request stream.
      await for (final request in requests) {
        _logger.internal('Sending request: $request');
        await send(request);
      }

      _logger.internal('Request stream finished, awaiting response');

      // Finish sending and get the response.
      return await finishSending();
    } catch (e) {
      _logger.error('Client stream call failed', error: e);
      rethrow;
    } finally {
      await close();
    }
  }

  /// Closes the stream and releases resources.
  Future<void> close() async {
    _logger.internal('Closing ClientStreamCaller');
    await _subscription?.cancel();
    await _processor.close();
  }
}
