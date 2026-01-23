// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

part of '../_index.dart';

/// Unary client: sends one request, gets one response (per call stream ID).
final class UnaryCaller<TRequest, TResponse> {
  /// Transport.
  final IRpcTransport _transport;

  /// Service name.
  final String _serviceName;

  /// Method name.
  final String _methodName;

  /// Method path `/Service/Method`.
  late final String _methodPath;

  /// Request codec.
  final IRpcCodec<TRequest> _requestSerializer;

  /// Response codec.
  final IRpcCodec<TResponse> _responseSerializer;

  /// RPC context.
  final RpcContext? _context;

  /// Logger.
  late final RpcLogger? _logger;

  /// Frame parser.
  late final RpcMessageParser _parser;

  String? _peerGrpcEncoding;

  /// Creates a unary client.
  UnaryCaller({
    required IRpcTransport transport,
    required String serviceName,
    required String methodName,
    required IRpcCodec<TRequest> requestCodec,
    required IRpcCodec<TResponse> responseCodec,
    RpcContext? context,
    RpcLogger? logger,
  })  : _transport = transport,
        _serviceName = serviceName,
        _methodName = methodName,
        _requestSerializer = requestCodec,
        _responseSerializer = responseCodec,
        _context = context {
    _logger = logger?.child('UnaryCaller');
    _parser = RpcMessageParser(
      logger: _logger,
      decompressor: (payload) {
        final encoding = _peerGrpcEncoding;
        if (encoding == null || encoding == RpcGrpcCompression.identity) {
          throw RpcException(
            'Compressed gRPC payload received without grpc-encoding',
          );
        }
        return RpcGrpcCompression.decompress(payload, encoding: encoding);
      },
    );
    _methodPath = '/$_serviceName/$_methodName';
    _logger?.internal(
      'Created unary client for $_methodPath${_context != null ? ' with context' : ''}',
    );
  }

  /// Executes the unary call.
  Future<TResponse> call(TRequest request, {Duration? timeout}) async {
    // Check cancellation and deadline from context.
    _checkContextBeforeCall();

    // Determine timeout: parameter, context, or default.
    final remainingTime = _context?.remainingTime;
    final effectiveTimeout =
        timeout ?? remainingTime ?? const Duration(seconds: 30);

    // Create a new stream for this call.
    final streamId = _transport.createStream();

    _logger?.internal('Unary call $_methodPath started [streamId: $streamId]');

    final completer = Completer<TResponse>();
    StreamSubscription? subscription;
    StreamSubscription? cancellationSubscription;

    try {
      // Subscribe to cancellation token if present.
      if (_context?.cancellationToken != null) {
        cancellationSubscription =
            _context!.cancellationToken!.cancelled.asStream().listen((_) {
          if (!completer.isCompleted) {
            _logger?.warning(
              'Operation cancelled via cancellation token [streamId: $streamId]',
            );
            completer.completeError(
              RpcCancelledException(
                _context!.cancellationToken!.reason ??
                    'Operation was cancelled',
              ),
            );
          }
        });
      }

      // Subscribe to responses for this stream.
      _logger
          ?.internal('Configuring response subscription [streamId: $streamId]');
      subscription = _transport.getMessagesForStream(streamId).listen(
        (message) async {
          if (message.isDirect && message.directPayload != null) {
            // Zero-copy: received object directly.
            _logger?.internal(
              'Zero-copy response received [streamId: $streamId]',
            );
            try {
              final response = message.directPayload as TResponse;
              if (!completer.isCompleted) {
                _logger?.internal(
                  'Zero-copy unary call $_methodPath completed [streamId: $streamId]',
                );
                completer.complete(response);
              } else {
                _logger?.warning(
                  'Extra zero-copy response after call completion [streamId: $streamId]',
                );
              }
            } catch (e, stackTrace) {
              if (!completer.isCompleted) {
                _logger?.error(
                  'Failed to process zero-copy response [streamId: $streamId]',
                  error: e,
                  stackTrace: stackTrace,
                );
                completer.completeError(e);
              }
            }
          } else if (!message.isMetadataOnly && message.payload != null) {
            // Received response data (serialized).
            _logger?.internal(
              'Received transport message of ${message.payload!.length} bytes [streamId: $streamId]',
            );
            try {
              // Use parser to extract messages from framed payload.
              final messages = _parser(message.payload!);
              _logger?.internal(
                'Parser extracted ${messages.length} messages from frame [streamId: $streamId]',
              );

              for (final msgBytes in messages) {
                _logger?.internal(
                  'Deserializing response of ${msgBytes.length} bytes [streamId: $streamId]',
                );
                final response = _responseSerializer.deserialize(msgBytes);
                if (!completer.isCompleted) {
                  _logger?.internal(
                    'Unary call $_methodPath completed [streamId: $streamId]',
                  );
                  completer.complete(response);
                  break; // Only first response is needed for unary call.
                } else {
                  _logger?.warning(
                    'Extra response after call completion [streamId: $streamId]',
                  );
                }
              }
            } catch (e, stackTrace) {
              if (!completer.isCompleted) {
                _logger?.error(
                  'Failed to process response [streamId: $streamId]',
                  error: e,
                  stackTrace: stackTrace,
                );
                completer.completeError(e);
              }
            }
          } else if (message.isMetadataOnly && message.metadata != null) {
            // Received metadata (possibly trailers).
            _logger?.internal('Metadata received [streamId: $streamId]');
            final encoding = message.metadata!.getHeaderValue(
              RpcConstants.grpcEncodingHeader,
            );
            if (encoding != null) {
              _peerGrpcEncoding = encoding;
            }
            final statusCode = message.metadata!.getHeaderValue(
              RpcConstants.grpcStatusHeader,
            );

            if (statusCode != null && message.isEndOfStream) {
              final code = int.tryParse(statusCode) ?? RpcStatus.unknown;
              _logger?.internal(
                'Completion status received: $code [streamId: $streamId]',
              );
              if (code != RpcStatus.ok && !completer.isCompleted) {
                final errorMessage = message.metadata!.getHeaderValue(
                      RpcConstants.grpcMessageHeader,
                    ) ??
                    '';
                final decodedMessage =
                    RpcMetadata.decodeGrpcMessage(errorMessage);
                _logger?.error(
                  'gRPC error: $code - $decodedMessage [streamId: $streamId]',
                );
                completer.completeError(
                  Exception('gRPC error $code: $decodedMessage'),
                );
              }
            }
          }
        },
        onError: (error, stackTrace) {
          _logger?.error(
            'Transport error [streamId: $streamId]',
            error: error,
            stackTrace: stackTrace,
          );
          if (!completer.isCompleted) {
            completer.completeError(error);
          }
        },
      );

      // Send initial metadata with context headers.
      _logger?.internal('Sending initial metadata [streamId: $streamId]');
      final baseMetadata = RpcMetadata.forClientRequest(
        _serviceName,
        _methodName,
      );

      // Build metadata with context headers.
      final headers = List<RpcHeader>.from(baseMetadata.headers);

      if (_context != null) {
        // Add custom context headers.
        for (final entry in _context!.headers.entries) {
          headers.add(RpcHeader(entry.key, entry.value));
        }

        // Add RPC-specific headers.
        if (_context!.traceId != null) {
          headers.add(RpcHeader('x-trace-id', _context!.traceId!));
        }
        headers.add(RpcHeader('x-request-id', _context!.requestId));

        // Send deadline to server.
        if (_context!.deadline != null) {
          final timeout = _context!.remainingTime;
          if (timeout != null) {
            headers.add(
              RpcHeader(
                RpcConstants.grpcTimeoutHeader,
                RpcMetadata.encodeGrpcTimeout(timeout),
              ),
            );
          }
          headers.add(
            RpcHeader(
              'x-deadline',
              _context!.deadline!.millisecondsSinceEpoch.toString(),
            ),
          );
        }

        _logger?.internal(
          'Context headers added: ${_context!.headers.length} custom + system',
        );
      }

      final metadata = RpcMetadata(headers);
      await _transport.sendMetadata(streamId, metadata);

      // Zero-copy optimization for supporting transports.
      if (_transport.supportsZeroCopy) {
        _logger?.internal('Zero-copy request send [streamId: $streamId]');
        await _transport.sendDirectObject(
          streamId,
          request as Object,
          endStream: true,
        );
      } else {
        // Standard serialization for other transports.
        _logger?.internal('Serializing request [streamId: $streamId]');
        final serializedRequest = _requestSerializer.serialize(request);
        final requestEncoding = _context?.getHeader(
          RpcConstants.grpcEncodingHeader,
        );
        final useCompression = requestEncoding != null &&
            requestEncoding != RpcGrpcCompression.identity;
        final payload = useCompression
            ? RpcGrpcCompression.compress(
                serializedRequest,
                encoding: requestEncoding,
              )
            : serializedRequest;
        _logger?.internal(
          'Request serialized, size: ${serializedRequest.length} bytes [streamId: $streamId]',
        );
        final framedRequest = RpcMessageFrame.encode(
          payload,
          compressed: useCompression,
        );
        _logger?.internal(
          'Sending request and closing request stream [streamId: $streamId]',
        );
        await _transport.sendMessage(streamId, framedRequest, endStream: true);
      }

      // Await response with timeout if provided.
      _logger?.internal(
        'Response timeout set to $effectiveTimeout [streamId: $streamId]',
      );
      return await completer.future.timeout(
        effectiveTimeout,
        onTimeout: () {
          _logger?.error(
            'Response timeout: $effectiveTimeout [streamId: $streamId]',
          );
          throw TimeoutException(
            'Call timeout: $effectiveTimeout',
            effectiveTimeout,
          );
        },
      );
    } catch (e, stackTrace) {
      _logger?.error(
        'Unary call $_methodPath failed [streamId: $streamId]',
        error: e,
        stackTrace: stackTrace,
      );
      rethrow;
    } finally {
      // Always cancel response stream subscription.
      _logger
          ?.internal('Cancelling response subscription [streamId: $streamId]');
      await subscription?.cancel();
      await cancellationSubscription?.cancel();
    }
  }

  /// Closes the client; transport remains open.
  Future<void> close() async {
    // Client does not own the transport, so do not close it.
    _logger?.internal('Unary client $_methodPath closed');
  }

  /// Validates context before call.
  void _checkContextBeforeCall() {
    if (_context == null) return;

    // Check cancellation.
    _context!.cancellationToken?.throwIfCancelled();

    // Check deadline.
    if (_context!.isExpired) {
      throw RpcDeadlineExceededException(_context!.deadline!, Duration.zero);
    }

    _logger?.internal(
      'Context verified: requestId=${_context!.requestId}, traceId=${_context!.traceId}',
    );
  }
}
