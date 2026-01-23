// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

part of '../_index.dart';

/// Unary responder with Stream ID support: handles one request, sends one response.
final class UnaryResponder<TRequest, TResponse> implements IRpcResponder {
  /// Transport.
  final IRpcTransport _transport;

  @override
  final int id;

  /// Service name.
  final String _serviceName;

  /// Method name.
  final String _methodName;

  /// Method path.
  late final String _methodPath;

  /// Request codec.
  final IRpcCodec<TRequest> _requestSerializer;

  /// Response codec.
  final IRpcCodec<TResponse> _responseSerializer;

  /// Logger.
  late final RpcLogger? _logger;

  /// RPC context with cancellation/metadata.
  final RpcContext? _context;

  /// Cancellation subscription.
  StreamSubscription? _cancellationSubscription;

  /// Frame parser.
  late final RpcMessageParser _parser;

  /// Incoming messages subscription.
  StreamSubscription? _subscription;

  /// Request handler.
  late final FutureOr<TResponse> Function(TRequest request) _handler;

  /// Stream state tracking.
  final Map<int, bool> _streamRequestHandled = <int, bool>{};
  final Map<int, bool> _streamInitialHeadersSent = <int, bool>{};
  final Map<int, bool> _streamBelongsToThisMethod = <int, bool>{};

  /// Creates a unary responder.
  UnaryResponder({
    this.id = 0,
    required IRpcTransport transport,
    required String serviceName,
    required String methodName,
    required IRpcCodec<TRequest> requestCodec,
    required IRpcCodec<TResponse> responseCodec,
    required FutureOr<TResponse> Function(TRequest request) handler,
    RpcContext? context,
    RpcLogger? logger,
  })  : _transport = transport,
        _serviceName = serviceName,
        _methodName = methodName,
        _requestSerializer = requestCodec,
        _responseSerializer = responseCodec,
        _context = context {
    _handler = handler;
    _logger = logger?.child('UnaryResponder');
    _parser = RpcMessageParser(
      logger: _logger,
      decompressor: (payload) {
        final encoding = _context?.getHeader(RpcConstants.grpcEncodingHeader);
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
      'Created unary server for $_methodPath${_context?.cancellationToken != null ? " with cancellation token" : ""}',
    );

    // Register initial stream as belonging to this method.
    _streamBelongsToThisMethod[id] = true;

    _setupCancellationMonitoring();
    _setupRequestHandler();
  }

  /// Sets up cancellation monitoring.
  void _setupCancellationMonitoring() {
    if (_context?.cancellationToken != null) {
      _cancellationSubscription =
          _context!.cancellationToken!.cancelled.asStream().listen(
        (_) {
          _logger?.internal(
            'Operation cancelled, stopping request handling [id: $id]',
          );

          // Cancel subscription to incoming messages.
          _subscription?.cancel();
        },
        onError: (error, stackTrace) {
          _logger?.error(
            'Error monitoring cancellation [id: $id]',
            error: error,
            stackTrace: stackTrace,
          );
        },
      );
    }
  }

  /// Throws if cancellation token is triggered.
  void _checkCancellation() {
    _context?.cancellationToken?.throwIfCancelled();
  }

  void _setupRequestHandler() {
    _logger?.internal('Configuring request handler for $_methodPath');

    _subscription = _transport.incomingMessages.listen(
      (message) async {
        final streamId = message.streamId;

        // If responder id is 0 (default), accept any messages (useful for tests).
        if (id != 0 && streamId != id) {
          return;
        }

        // For metadata, ensure it targets this method.
        if (message.isMetadataOnly && message.metadata != null) {
          if (message.methodPath == _methodPath) {
            _streamBelongsToThisMethod[streamId] = true;
            _logger?.internal(
              'Unary server: stream $streamId bound to method $_methodPath',
            );
          }
          return; // Register metadata only.
        }

        // For data messages, ensure they belong to this method.
        if (!_streamBelongsToThisMethod.containsKey(streamId)) {
          return; // Not for this responder.
        }

        if (_streamRequestHandled[streamId] == true) {
          // Ignore additional messages after first request handled.
          _logger?.internal(
            'Ignoring extra message for stream $streamId (request already handled)',
          );
          return;
        }

        // Check cancellation before processing.
        try {
          _checkCancellation();
        } catch (e) {
          _logger?.internal(
            'Message skipped due to cancellation [streamId: $streamId]',
          );
          return;
        }

        if (message.isDirect && message.directPayload != null) {
          // Zero-copy: handle object directly.
          await handleDirectMessage(message);
        } else if (!message.isMetadataOnly && message.payload != null) {
          await handleMessage(message);
        }

        // If the client closed the stream without sending data.
        if (message.isEndOfStream &&
            _streamBelongsToThisMethod[streamId] == true &&
            _streamRequestHandled[streamId] != true) {
          _streamRequestHandled[streamId] = true;
          _logger?.warning(
            'Client closed stream without sending data [streamId: $streamId]',
          );

          // Send an error trailer.
          await _transport.sendMetadata(
            streamId,
            RpcMetadata.forTrailer(
              RpcStatus.invalidArgument,
              message: 'Request not received: stream closed without data',
            ),
            endStream: true,
          );

          // Clear state for this stream.
          _streamRequestHandled.remove(streamId);
          _streamInitialHeadersSent.remove(streamId);
          _streamBelongsToThisMethod.remove(streamId);
        }
      },
      onError: (error, stackTrace) async {
        _logger?.error(
          'Transport error for $_methodPath',
          error: error,
          stackTrace: stackTrace,
        );
      },
    );
  }

  /// Handles a payload message (can be called for pre-received messages).
  Future<void> handleMessage(RpcTransportMessage message) async {
    final streamId = message.streamId;

    // Check cancellation before processing.
    try {
      _checkCancellation();
    } catch (e) {
      _logger?.internal('Message processing cancelled [streamId: $streamId]');
      return;
    }

    // Ensure the message targets this responder (id=0 accepts all for tests).
    if (id != 0 && streamId != id) {
      _logger?.internal(
        'Message for stream $streamId does not belong to this responder (id=$id), skipping',
      );
      return;
    }

    if (_streamRequestHandled[streamId] == true) {
      _logger?.internal(
        'Message for stream $streamId already handled, skipping',
      );
      return;
    }

    if (message.isMetadataOnly || message.payload == null) {
      _logger?.internal('Received message without payload, skipping');
      return;
    }

    // Mark as handling immediately to prevent duplicates.
    _streamRequestHandled[streamId] = true;
    _logger?.internal(
      'Handling request for $_methodPath [streamId: $streamId]',
    );

    try {
      // Send initial headers if not already sent.
      if (_streamInitialHeadersSent[streamId] != true) {
        _logger?.internal(
          'Sending initial headers [streamId: $streamId]',
        );
        await _transport.sendMetadata(
          streamId,
          RpcMetadata.forServerInitialResponse(),
        );
        _streamInitialHeadersSent[streamId] = true;
      }

      // Deserialize request using parser to extract framed messages.
      _logger?.internal(
        'Parsing request frame of ${message.payload!.length} bytes [streamId: $streamId]',
      );
      final messages = _parser(message.payload!);
      if (messages.isEmpty) {
        _logger?.error(
          'Failed to extract message from payload [streamId: $streamId]',
        );
        throw Exception('Failed to extract message from payload');
      }

      _logger?.internal('Deserializing request [streamId: $streamId]');
      final request = _requestSerializer.deserialize(messages.first);

      _logger?.internal(
        'Handling request for $_methodPath [streamId: $streamId]',
      );

      // Handle request.
      final response = await _handler(request);
      _logger?.internal(
        'Request handled, preparing response [streamId: $streamId]',
      );

      // Serialize and send response.
      _logger?.internal('Serializing response [streamId: $streamId]');
      final serializedResponse = _responseSerializer.serialize(response);
      _logger?.internal(
        'Response serialized, size: ${serializedResponse.length} bytes [streamId: $streamId]',
      );
      final framedResponse = RpcMessageFrame.encode(serializedResponse);
      _logger?.internal('Sending response [streamId: $streamId]');
      await _transport.sendMessage(streamId, framedResponse);

      // Send success trailer.
      _logger?.internal(
        'Sending success trailer [streamId: $streamId]',
      );
      await _transport.sendMetadata(
        streamId,
        RpcMetadata.forTrailer(RpcStatus.ok),
        endStream: true,
      );

      _logger?.internal(
        'Response sent for $_methodPath [streamId: $streamId]',
      );
    } catch (e, stackTrace) {
      _logger?.error(
        'Request processing failed [streamId: $streamId]',
        error: e,
        stackTrace: stackTrace,
      );

      // Send initial headers if not already sent.
      if (_streamInitialHeadersSent[streamId] != true) {
        await _transport.sendMetadata(
          streamId,
          RpcMetadata.forServerInitialResponse(),
        );
        _streamInitialHeadersSent[streamId] = true;
      }

      // On error, send trailer with status.
      _logger?.internal('Sending error trailer [streamId: $streamId]');
      await _transport.sendMetadata(
        streamId,
        RpcMetadata.forTrailer(
          RpcStatus.internal,
          message: 'Request processing error: $e',
        ),
        endStream: true,
      );
    } finally {
      // Clear state for this stream.
      _logger?.internal('Clearing state for stream $streamId');
      _streamRequestHandled.remove(streamId);
      _streamInitialHeadersSent.remove(streamId);
      _streamBelongsToThisMethod.remove(streamId);
    }
  }

  /// Zero-copy payload handling.
  Future<void> handleDirectMessage(RpcTransportMessage message) async {
    final streamId = message.streamId;

    // Check cancellation before processing.
    try {
      _checkCancellation();
    } catch (e) {
      _logger?.internal(
        'Zero-copy message processing cancelled [streamId: $streamId]',
      );
      return;
    }

    // Ensure message targets this responder.
    if (id != 0 && streamId != id) {
      _logger?.internal(
        'Zero-copy message for stream $streamId does not belong to this responder (id=$id), skipping',
      );
      return;
    }

    if (_streamRequestHandled[streamId] == true) {
      _logger?.internal(
        'Zero-copy message for stream $streamId already handled, skipping',
      );
      return;
    }

    // Mark as handling immediately.
    _streamRequestHandled[streamId] = true;
    _logger?.internal(
      'Zero-copy request processing for $_methodPath [streamId: $streamId]',
    );

    try {
      // Send initial headers if not already sent.
      if (_streamInitialHeadersSent[streamId] != true) {
        _logger?.internal(
          'Sending initial headers [streamId: $streamId]',
        );
        await _transport.sendMetadata(
          streamId,
          RpcMetadata.forServerInitialResponse(),
        );
        _streamInitialHeadersSent[streamId] = true;
      }

      // Zero-copy: get object directly without deserialization.
      _logger?.internal('Zero-copy object access [streamId: $streamId]');
      final request = message.directPayload as TRequest;

      _logger?.internal(
        'Zero-copy request handling for $_methodPath [streamId: $streamId]',
      );

      // Handle request.
      final response = await _handler(request);
      _logger?.internal(
        'Zero-copy request completed, preparing response [streamId: $streamId]',
      );

      // Zero-copy: send response directly if supported.
      if (_transport.supportsZeroCopy) {
        _logger?.internal('Zero-copy response sending [streamId: $streamId]');
        await _transport.sendDirectObject(streamId, response as Object);
      } else {
        // Fallback to standard serialization for other transports.
        _logger
            ?.internal('Fallback response serialization [streamId: $streamId]');
        final serializedResponse = _responseSerializer.serialize(response);
        final framedResponse = RpcMessageFrame.encode(serializedResponse);
        await _transport.sendMessage(streamId, framedResponse);
      }

      // Send success trailer.
      _logger?.internal(
        'Zero-copy sending success trailer [streamId: $streamId]',
      );
      await _transport.sendMetadata(
        streamId,
        RpcMetadata.forTrailer(RpcStatus.ok),
        endStream: true,
      );

      _logger?.internal(
        'Zero-copy response completed for $_methodPath [streamId: $streamId]',
      );
    } catch (e, stackTrace) {
      _logger?.error(
        'Zero-copy request processing error [streamId: $streamId]',
        error: e,
        stackTrace: stackTrace,
      );

      // Send initial headers if not already sent.
      if (_streamInitialHeadersSent[streamId] != true) {
        await _transport.sendMetadata(
          streamId,
          RpcMetadata.forServerInitialResponse(),
        );
        _streamInitialHeadersSent[streamId] = true;
      }

      // On error, send error trailer.
      await _transport.sendMetadata(
        streamId,
        RpcMetadata.forTrailer(RpcStatus.internal, message: e.toString()),
        endStream: true,
      );
    } finally {
      // Clear state for this stream.
      _logger?.internal('Zero-copy cleanup for stream $streamId');
      _streamRequestHandled.remove(streamId);
      _streamInitialHeadersSent.remove(streamId);
      _streamBelongsToThisMethod.remove(streamId);
    }
  }

  /// Closes the responder; transport remains open.
  Future<void> close() async {
    _logger?.internal('Closing unary server $_methodPath');
    await _subscription?.cancel();
    await _cancellationSubscription?.cancel();
    _logger?.internal('All subscriptions cancelled');
  }
}
