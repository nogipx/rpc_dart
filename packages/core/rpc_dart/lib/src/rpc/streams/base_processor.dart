// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

part of '_index.dart';

/// Returns true if [error] indicates the underlying transport is closed.
///
/// Network transports (HTTP/1.1, HTTP/2, ...) signal a closed transport with
/// `StateError('Transport is closed')`. We match the exact type and message
/// instead of a broad `toString().contains('closed')`, which would otherwise
/// swallow unrelated errors whose text merely contains "closed".
bool _isTransportClosed(Object error) {
  return error is StateError && error.message == 'Transport is closed';
}

/// Compresses [serialized] with [encoding] (null or `identity` = no
/// compression), wraps it in the gRPC 5-byte frame, and sends it on [streamId].
///
/// Shared by the request (client) and response (server) send paths, which were
/// byte-for-byte identical here. [encoding] must already be resolved/validated
/// by the caller.
Future<void> _frameAndSend(
  IRpcTransport transport,
  int streamId,
  Uint8List serialized,
  String? encoding,
) {
  final useCompression =
      encoding != null && encoding != RpcGrpcCompression.identity;
  final payload = useCompression
      ? RpcGrpcCompression.compress(serialized, encoding: encoding)
      : serialized;
  final framed = RpcMessageFrame.encode(payload, compressed: useCompression);
  return transport.sendMessage(streamId, framed);
}

/// Tells the peer that [streamId] was cancelled, so its handler can stop.
///
/// Prefers a transport-level reset. The metadata notice below rides on a frame
/// with `endStream: true`, which is only legal while this side is still open —
/// and by cancellation time it usually is not (every caller here half-closes
/// once its request is sent). Sending it anyway is a protocol violation that
/// HTTP/2 throws asynchronously out of its stream handler, corrupting the
/// connection; transports without stream state accept it fine.
///
/// Never throws: a best-effort courtesy to the peer must not turn a cancelled
/// call into a failed teardown.
Future<void> _notifyPeerOfCancellation(
  IRpcTransport transport,
  int streamId,
  String reason,
  LogScope logger,
) async {
  if (transport is IRpcStreamReset) {
    try {
      final reset = await (transport as IRpcStreamReset).resetStream(
        streamId,
        reason: reason,
      );
      if (reset) {
        logger.internal(
          'Cancellation delivered via stream reset [streamId: $streamId]',
        );
        return;
      }
    } catch (error, stackTrace) {
      logger.warning(
        'Stream reset failed, falling back to cancellation metadata '
        '[streamId: $streamId]',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  try {
    final cancellationMetadata = RpcMetadata([
      RpcHeader(RpcHeaders.xClientCancelled, 'true'),
      RpcHeader(RpcHeaders.xCancellationReason, reason),
      RpcHeader(RpcHeaders.grpcStatus, RpcStatus.cancelled.toString()),
    ]);

    logger.internal(
      'Sending cancellation notice to server [streamId: $streamId]',
    );
    await transport.sendMetadata(
      streamId,
      cancellationMetadata,
      endStream: true,
    );
    logger.internal('Cancellation notice sent to server [streamId: $streamId]');
  } catch (e, stackTrace) {
    logger.error(
      'Failed to send cancellation metadata [streamId: $streamId]',
      error: e,
      stackTrace: stackTrace,
    );
  }
}

/// Shared stream processor: zero-copy when no codecs (zero-copy transport required), otherwise serialized.
final class StreamProcessor<TRequest extends Object, TResponse extends Object> {
  final LogScope _logger;
  final IRpcTransport _transport;
  final int _streamId;
  final String _serviceName;
  final String _methodName;
  final IRpcCodec<TRequest>? _requestCodec;
  final IRpcCodec<TResponse>? _responseCodec;

  /// RPC context with cancellation/metadata.
  final RpcContext? _context;

  /// Call scope for automatic resource cleanup.
  final RpcCallScope _scope;

  /// Parser for fragmented messages (serialization mode only).
  RpcMessageParser? _parser;

  /// Whether zero-copy mode is active.
  final bool _isZeroCopy;

  /// Incoming requests controller.
  final StreamController<TRequest> _requestController =
      StreamController<TRequest>();

  /// Outgoing responses controller.
  final StreamController<TResponse> _responseController =
      StreamController<TResponse>();

  /// Send sequence to preserve order and await completion before trailers.
  Future<void> _sendSequence = Future<void>.value();

  bool _trailerSent = false;

  /// Processor active flag.
  bool _isActive = true;

  /// Indicates initial metadata sent.
  bool _initialMetadataSent = false;

  /// Response encoding selected from client's grpc-accept-encoding.
  /// Null means identity (no compression).
  /// Initially set from server context; overridden by incoming client metadata.
  String? _responseEncoding;

  /// Request encoding advertised by the peer in grpc-encoding.
  /// Set when the initial request metadata arrives; used by the decompressor.
  String? _requestEncoding;

  /// Method path `/Service/Method`.
  late final String _methodPath;

  /// Creates a [StreamProcessor] for the given transport and stream.
  StreamProcessor({
    required IRpcTransport transport,
    required int streamId,
    required String serviceName,
    required String methodName,
    IRpcCodec<TRequest>? requestCodec,
    IRpcCodec<TResponse>? responseCodec,
    RpcContext? context,
    LogScope? logger,
  }) : _transport = transport,
       _streamId = streamId,
       _serviceName = serviceName,
       _methodName = methodName,
       _isZeroCopy = requestCodec == null && responseCodec == null,
       _requestCodec = requestCodec,
       _responseCodec = responseCodec,
       _context = context,
       _scope = RpcCallScope(context: context),
       _logger = logger?.child('StreamProcessor') ?? LogScope.noop {
    // Serialization requires codecs.
    if (!_isZeroCopy) {
      if (_requestCodec == null || _responseCodec == null) {
        throw ArgumentError(
          'Codecs are required for serialization mode. '
          'For zero-copy leave codecs null.',
        );
      }
      _parser = RpcMessageParser(
        logger: _logger,
        decompressor: (payload, {int? maxOutputBytes}) {
          final encoding =
              _requestEncoding ?? _context?.getHeader(RpcHeaders.grpcEncoding);
          if (encoding == null || encoding == RpcGrpcCompression.identity) {
            throw RpcStatusException(
              RpcStatus.internal,
              'Compressed gRPC payload received without grpc-encoding',
            );
          }
          return RpcGrpcCompression.decompress(
            payload,
            encoding: encoding,
            maxOutputBytes: maxOutputBytes,
          );
        },
      );
    } else {
      // Zero-copy requires transport support.
      if (!transport.supportsZeroCopy) {
        throw ArgumentError(
          'Zero-copy mode requires a transport with zero-copy support. '
          'Provide codecs for network transports.',
        );
      }
    }

    _methodPath = '/$_serviceName/$_methodName';
    _responseEncoding = _pickResponseEncoding(context);

    _logger.internal(
      'Created ${_isZeroCopy ? "Zero-copy" : "Serialized"} StreamProcessor for $_methodPath [streamId: $_streamId]${_context?.cancellationToken != null ? " with cancellation token" : ""}',
    );

    // Register controller cleanup with scope.
    _scope.onDispose(() {
      if (!_requestController.isClosed) _requestController.close();
      if (!_responseController.isClosed) _responseController.close();
    });

    _setupCancellationMonitoring();
    _setupResponseHandler();
  }

  /// Picks the best response encoding from the client's grpc-accept-encoding.
  static String? _pickResponseEncoding(RpcContext? context) {
    final accept = context?.getHeader(RpcHeaders.grpcAcceptEncoding);
    return RpcGrpcCompression.selectResponseEncoding(accept);
  }

  /// The call scope managing this processor's resources.
  RpcCallScope get scope => _scope;

  /// Incoming request stream.
  Stream<TRequest> get requests => _requestController.stream;

  /// Whether processor is active.
  bool get isActive => _isActive;

  /// Zero-copy mode flag.
  bool get isZeroCopy => _isZeroCopy;

  /// Configures outgoing response handling.
  ///
  /// The actual transmission is queued synchronously by [send] onto
  /// [_sendSequence]; this listener exists only so that the response
  /// controller's stream is consumed (and any errors pushed onto it, e.g.
  /// cancellation, are observed and logged). Data events are intentionally
  /// ignored here: queuing them asynchronously would race with
  /// [sendError]/[finishSending], which await [_sendSequence] and could
  /// otherwise close the controller before a just-sent message was queued,
  /// dropping the last message.
  void _setupResponseHandler() {
    _scope.listen<TResponse>(
      _responseController.stream,
      (response) {
        // No-op: transmission is queued synchronously in send().
      },
      onError: (error, stackTrace) {
        _logger.error(
          'Error in response stream for $_methodPath [streamId: $_streamId]',
          error: error,
          stackTrace: stackTrace,
        );
      },
    );
  }

  /// Queues the transmission of [response] onto [_sendSequence].
  ///
  /// Called synchronously from [send] so that a subsequent
  /// [sendError]/[finishSending] awaiting [_sendSequence] always observes the
  /// queued write and never drops the last message.
  void _transmitResponse(TResponse response) {
    _sendSequence = _sendSequence.then((_) async {
      if (!_isActive) return;

      if (_logger.isInternal) {
        _logger.internal(
          'Sending response for $_methodPath [streamId: $_streamId]',
        );
      }
      try {
        if (_isZeroCopy) {
          // Zero-copy path
          if (_logger.isInternal) {
            _logger.internal('Zero-copy send [streamId: $_streamId]');
          }
          await _transport.sendDirectObject(_streamId, response);
          if (_logger.isInternal) {
            _logger.internal(
              'Zero-copy response sent for $_methodPath [streamId: $_streamId]',
            );
          }
        } else {
          // Send initial metadata before the first response frame only when
          // we need to advertise compression. Without compression the
          // existing behaviour (no initial metadata for streaming) is kept
          // so existing tests and in-memory transports are not affected.
          if (_responseEncoding != null && !_initialMetadataSent) {
            await _transport.sendMetadata(
              _streamId,
              RpcMetadata.forServerInitialResponse(encoding: _responseEncoding),
            );
            _initialMetadataSent = true;
          }

          // Serialization for network transports
          final serialized = _responseCodec!.serialize(response);
          if (_logger.isInternal) {
            _logger.internal(
              'Response serialized (${serialized.length} bytes) [streamId: $_streamId]',
            );
          }
          await _frameAndSend(
            _transport,
            _streamId,
            serialized,
            _responseEncoding,
          );

          if (_logger.isInternal) {
            _logger.internal(
              'Response sent for $_methodPath [streamId: $_streamId]',
            );
          }
        }
      } catch (e, stackTrace) {
        // Skip only when the transport itself is closed. Network transports
        // signal this with StateError('Transport is closed'); match the
        // exact type+message instead of a broad substring search so we do
        // not swallow unrelated errors that merely mention "closed".
        if (_isTransportClosed(e)) {
          _logger.debug(
            'Transport closed, skipping response send [streamId: $_streamId]',
          );
          return;
        }
        _logger.error(
          'Failed to send response [streamId: $_streamId]',
          error: e,
          stackTrace: stackTrace,
        );
      }
    });
  }

  Future<void> _sendOkTrailerIfNeeded() async {
    if (_trailerSent) return;
    _trailerSent = true;

    try {
      final trailers = RpcMetadata.forTrailer(RpcStatus.ok);
      await _transport.sendMetadata(_streamId, trailers, endStream: true);
      _logger.internal('Trailer sent for $_methodPath [streamId: $_streamId]');
    } catch (e, stackTrace) {
      if (_isTransportClosed(e)) {
        _logger.debug(
          'Transport closed, skipping trailer send [streamId: $_streamId]',
        );
        return;
      }
      _logger.error(
        'Failed to send trailer [streamId: $_streamId]',
        error: e,
        stackTrace: stackTrace,
      );
    }
  }

  bool _messageBound = false;

  /// Binds the processor to an endpoint message stream.
  void bindToMessageStream(Stream<RpcTransportMessage> messageStream) {
    if (_messageBound) {
      _logger.warning(
        'Stream processor already bound to message stream [methodPath: $_methodPath, streamId: $_streamId]',
      );
      return;
    }
    _messageBound = true;

    _logger.internal(
      'Stream bound [methodPath: $_methodPath, streamId: $_streamId]',
    );

    _scope.listen<RpcTransportMessage>(
      messageStream,
      _handleMessage,
      onError: (error, stackTrace) {
        _logger.error(
          'message_stream_listen error [methodPath: $_methodPath, streamId: $_streamId]',
          error: error,
          stackTrace: stackTrace,
        );
        if (!_requestController.isClosed) {
          _requestController.addError(error, stackTrace);
        }
      },
      onDone: () {
        _logger.internal(
          'Stream finished: message_stream_completed [methodPath: $_methodPath, streamId: $_streamId]',
        );
        if (!_requestController.isClosed) {
          _requestController.close();
        }
      },
    );

    // Initial metadata is not sent on bind; it is sent with the first response
    // or skipped when sending an immediate error.
  }

  /// Checks cancellation token and throws if cancelled.
  void _checkCancellation() {
    _context?.cancellationToken?.throwIfCancelled();
  }

  /// Handles an incoming transport message.
  void _handleMessage(RpcTransportMessage message) {
    if (!_isActive) return;

    // Check cancellation before handling each message.
    try {
      _checkCancellation();
    } catch (e) {
      _logger.internal(
        'Message skipped due to cancellation [streamId: $_streamId]',
      );
      return;
    }

    _logger.internal(
      'Message received [streamId: ${message.streamId}, type: ${message.isMetadataOnly
          ? "metadata"
          : message.isDirect
          ? "zero_copy"
          : "serialized"}, size: ${message.payload?.length}]',
    );

    // Extract encoding hints from initial request metadata.
    if (message.isMetadataOnly && message.metadata != null) {
      final meta = message.metadata!;

      // grpc-encoding: what the peer used to compress its requests.
      final reqEnc = meta.getHeaderValue(RpcHeaders.grpcEncoding);
      if (reqEnc != null && reqEnc != RpcGrpcCompression.identity) {
        _requestEncoding = reqEnc;
      }

      // grpc-accept-encoding: what the peer can decompress → use for responses.
      _responseEncoding ??= RpcGrpcCompression.selectResponseEncoding(
        meta.getHeaderValue(RpcHeaders.grpcAcceptEncoding),
      );
    }

    // Zero-copy: direct object.
    if (message.isDirect && message.directPayload != null) {
      _processDirectMessage(message.directPayload!);
    }
    // Serialized payload.
    else if (!message.isMetadataOnly && message.payload != null) {
      _processDataMessage(message.payload!);
    }

    // End of stream.
    if (message.isEndOfStream) {
      _logger.internal(
        'Stream finished: end_of_stream_received [methodPath: $_methodPath, streamId: $_streamId]',
      );
      if (!_requestController.isClosed) {
        _requestController.close();
      }
    }
  }

  /// Zero-copy: processes a direct object without serialization.
  void _processDirectMessage(Object directPayload) {
    try {
      final request = directPayload as TRequest;

      if (!_requestController.isClosed) {
        _requestController.add(request);
      } else {
        _logger.warning(
          'Cannot add request to closed controller (zero-copy) [methodPath: $_methodPath, streamId: $_streamId]',
        );
      }
    } catch (e, stackTrace) {
      _logger.error(
        'zero_copy_direct_object_processing error [methodPath: $_methodPath, streamId: $_streamId, type: ${directPayload.runtimeType}]',
        error: e,
        stackTrace: stackTrace,
      );
      if (!_requestController.isClosed) {
        _requestController.addError(e, stackTrace);
      }
    }
  }

  /// Processes a serialized message (serialization mode only).
  void _processDataMessage(List<int> messageBytes) {
    if (_isZeroCopy) {
      _logger.warning(
        'Serialized message received in zero-copy mode, ignoring [methodPath: $_methodPath, streamId: $_streamId]',
      );
      return;
    }

    _logger.internal(
      'Message received [streamId: $_streamId, type: serialized_data, size: ${messageBytes.length}]',
    );

    try {
      // Convert to Uint8List for parser.
      final uint8Message = messageBytes is Uint8List
          ? messageBytes
          : Uint8List.fromList(messageBytes);

      final messages = _parser!(uint8Message);

      for (var msgBytes in messages) {
        try {
          final request = _requestCodec!.deserialize(msgBytes);

          if (!_requestController.isClosed) {
            _requestController.add(request);
          } else {
            _logger.warning(
              'Cannot add request to closed controller [methodPath: $_methodPath, streamId: $_streamId, size: ${msgBytes.length}]',
            );
          }
        } catch (e, stackTrace) {
          _logger.error(
            'request_deserialization error [methodPath: $_methodPath, streamId: $_streamId, size: ${msgBytes.length}]',
            error: e,
            stackTrace: stackTrace,
          );
          if (!_requestController.isClosed) {
            _requestController.addError(e, stackTrace);
          }
        }
      }
    } catch (e, stackTrace) {
      _logger.error(
        'message_parsing error [methodPath: $_methodPath, streamId: $_streamId, size: ${messageBytes.length}]',
        error: e,
        stackTrace: stackTrace,
      );
      if (!_requestController.isClosed) {
        _requestController.addError(e, stackTrace);
      }
    }
  }

  /// Sends a response to the client.
  Future<void> send(TResponse response) async {
    if (!_isActive) {
      _logger.warning('Attempted to send response on inactive processor');
      return;
    }

    // Check cancellation before sending a response.
    try {
      _checkCancellation();
    } catch (e) {
      _logger.internal(
        'Response skipped due to cancellation [streamId: $_streamId]',
      );
      return;
    }

    if (!_responseController.isClosed) {
      // Queue the transmission synchronously so a subsequent
      // sendError()/finishSending() that awaits _sendSequence always observes
      // this write. Also forward to the controller so its stream keeps
      // draining (and errors pushed onto it are observed).
      _transmitResponse(response);
      _responseController.add(response);
    } else {
      _logger.warning('Attempted to send response to closed controller');
    }
  }

  /// Sends an error to the client.
  Future<void> sendError(
    int statusCode,
    String message, {
    Uint8List? statusDetailsBin,
  }) async {
    if (!_isActive) {
      _logger.warning('Attempted to send error on inactive processor');
      return;
    }

    _logger.error(
      'Sending error to client: $statusCode - $message [streamId: $_streamId]',
    );

    // Wait for pending sends to avoid interleaving the error trailer.
    await _sendSequence;

    if (!_responseController.isClosed) {
      await _responseController.close();
    }

    try {
      // If initial metadata was not sent, this becomes a Trailers-Only response.
      // The transport layer handles adding :status: 200 for Trailers-Only.
      if (!_initialMetadataSent) {
        _logger.internal('Sending Trailers-Only error [streamId: $_streamId]');
        _initialMetadataSent = true;
      }

      // Both Trailers-Only and post-data trailers use the same format:
      // grpc-status + optional grpc-message. The transport distinguishes
      // between the two based on whether initial headers were sent.
      final trailers = RpcMetadata.forTrailer(
        statusCode,
        message: message,
        statusDetailsBin: statusDetailsBin,
      );
      await _transport.sendMetadata(_streamId, trailers, endStream: true);

      _logger.internal('Error sent to client [streamId: $_streamId]');
      _trailerSent = true;
    } catch (e, stackTrace) {
      // Skip only when the transport is closed (see _isTransportClosed).
      if (_isTransportClosed(e)) {
        _logger.debug(
          'Transport closed, skipping error send [streamId: $_streamId]',
        );
        return;
      }
      _logger.error(
        'Failed to send error to client [streamId: $_streamId]',
        error: e,
        stackTrace: stackTrace,
      );
    }
  }

  /// Finishes sending responses.
  Future<void> finishSending() async {
    if (!_isActive) return;

    _logger.internal(
      'Finishing response send for $_methodPath [streamId: $_streamId]',
    );

    await _sendSequence;

    if (!_responseController.isClosed) {
      await _responseController.close();
    }

    await _sendOkTrailerIfNeeded();
  }

  /// Closes the processor and frees resources.
  ///
  /// Delegates to [RpcCallScope.close] which runs all registered
  /// disposers (subscriptions, controllers) in reverse order.
  Future<void> close() async {
    if (!_isActive) return;

    _logger.internal(
      'Closing StreamProcessor for $_methodPath [streamId: $_streamId]',
    );
    _isActive = false;

    await _scope.close();
  }

  /// Sets up cancellation monitoring via the call scope.
  ///
  /// The scope already auto-closes on cancellation/deadline, but we
  /// also need to push a [RpcCancelledException] into the controllers
  /// so that handlers see the cancellation error.
  void _setupCancellationMonitoring() {
    if (_context?.cancellationToken == null) return;

    _scope.listen<void>(
      _context!.cancellationToken!.cancelled.asStream(),
      (_) {
        _logger.internal(
          'Operation cancelled, shutting down processor [streamId: $_streamId]',
        );
        _isActive = false;

        final reason =
            _context.cancellationToken!.reason ?? 'Operation was cancelled';
        final cancelledException = RpcCancelledException(reason);

        try {
          // Single-subscription controller: addError buffers the error for a
          // late subscriber. Do NOT gate on hasListener — that would drop the
          // cancellation if it fires before the consumer subscribes.
          if (!_requestController.isClosed) {
            _requestController.addError(cancelledException);
          }
        } catch (e) {
          _logger.warning(
            'Failed to deliver cancellation to request stream [streamId: $_streamId]',
            error: e,
          );
        }
        try {
          // Single-subscription controller: addError buffers the error for a
          // late subscriber. Do NOT gate on hasListener — that would drop the
          // cancellation if it fires before the consumer subscribes.
          if (!_responseController.isClosed) {
            _responseController.addError(cancelledException);
          }
        } catch (e) {
          _logger.warning(
            'Failed to deliver cancellation to response stream [streamId: $_streamId]',
            error: e,
          );
        }
      },
      onError: (error, stackTrace) {
        _logger.error(
          'Error monitoring cancellation [streamId: $_streamId]',
          error: error,
          stackTrace: stackTrace,
        );
      },
    );
  }
}

/// Shared processor for client RPC stream calls.
///
/// Automatically selects mode:
/// - Zero-copy for in-memory transport (codecs not needed)
/// - Serialization for network transports (codecs required)
///
/// Benefits:
/// - Reuse across stream call types
/// - Avoids race conditions
/// - Clear separation of concerns
/// - Testable without out-of-process dependencies
/// - Works with any object types, not just IRpcSerializable
/// - Auto-optimized for in-memory transport
final class CallProcessor<TRequest extends Object, TResponse extends Object> {
  final LogScope _logger;
  final IRpcTransport _transport;
  final int _streamId;
  final String _serviceName;
  final String _methodName;
  final IRpcCodec<TRequest>? _requestCodec;
  final IRpcCodec<TResponse>? _responseCodec;

  /// RPC context for metadata, timeouts, and cancellation.
  final RpcContext? _context;

  /// Call scope for automatic resource cleanup.
  final RpcCallScope _scope;

  /// Parser for fragmented messages (serialization mode only).
  RpcMessageParser? _parser;

  String? _peerGrpcEncoding;

  /// Processor mode flag.
  final bool _isZeroCopy;

  /// Outgoing request controller.
  final StreamController<TRequest> _requestController =
      StreamController<TRequest>();

  /// Incoming response controller.
  final StreamController<RpcMessage<TResponse>> _responseController =
      StreamController<RpcMessage<TResponse>>();

  /// Send sequence to preserve order and await completion before finishing.
  Future<void> _sendSequence = Future<void>.value();

  /// Processor active flag.
  bool _isActive = true;

  /// Whether initial metadata was sent.
  bool _initialMetadataSent = false;

  /// Method path in /Service/Method format.
  late final String _methodPath;

  /// Creates a [CallProcessor] for the given transport and method.
  CallProcessor({
    required IRpcTransport transport,
    required String serviceName,
    required String methodName,
    IRpcCodec<TRequest>? requestCodec,
    IRpcCodec<TResponse>? responseCodec,
    RpcContext? context,
    LogScope? logger,
  }) : _transport = transport,
       _streamId = transport.createStream(),
       _serviceName = serviceName,
       _methodName = methodName,
       _isZeroCopy = requestCodec == null && responseCodec == null,
       _requestCodec = requestCodec,
       _responseCodec = responseCodec,
       _context = context,
       _scope = RpcCallScope(context: context),
       _logger = logger?.child('CallProcessor') ?? LogScope.noop {
    try {
      // Validation: codecs are required for serialization mode.
      if (!_isZeroCopy) {
        if (_requestCodec == null || _responseCodec == null) {
          throw ArgumentError(
            'Codecs are required for serialization mode. '
            'For zero-copy leave codecs null.',
          );
        }
        _parser = RpcMessageParser(
          logger: _logger,
          decompressor: (payload, {int? maxOutputBytes}) {
            final encoding = _peerGrpcEncoding;
            if (encoding == null || encoding == RpcGrpcCompression.identity) {
              throw RpcStatusException(
                RpcStatus.internal,
                'Compressed gRPC payload received without grpc-encoding',
              );
            }
            return RpcGrpcCompression.decompress(
              payload,
              encoding: encoding,
              maxOutputBytes: maxOutputBytes,
            );
          },
        );
      } else {
        // Zero-copy mode requires transport support.
        if (!transport.supportsZeroCopy) {
          throw ArgumentError(
            'Zero-copy mode requires a transport with zero-copy support. '
            'Provide codecs for network transports.',
          );
        }
      }

      _methodPath = '/$_serviceName/$_methodName';

      _logger.internal(
        'Created ${_isZeroCopy ? "Zero-copy" : "Serialized"} CallProcessor for $_methodPath [streamId: $_streamId]${_context?.cancellationToken != null ? " with cancellation token" : ""}',
      );

      // Register controller cleanup and stream-id release with scope.
      _scope.onDispose(() {
        // Free the transport stream id so a closed/aborted call (cancellation,
        // deadline, error) releases its slot. The normal finishSending path
        // releases it too, and releaseStreamId is idempotent, so a double
        // release is harmless.
        _transport.releaseStreamId(_streamId);
        if (!_requestController.isClosed) _requestController.close();
        if (!_responseController.isClosed) _responseController.close();
      });

      // Validate context before starting.
      _checkContextBeforeCall();

      _setupDeadlineMonitoring();
      _setupCancellationMonitoring();
      _setupRequestHandler();
      _setupResponseHandler();
    } catch (_) {
      // createStream() ran in the initializer list, so a throw in the body
      // (invalid codecs, or an already-expired deadline tripping
      // _checkContextBeforeCall) would leak the allocated stream id: the caller
      // never receives an instance, so close() never runs. Release it here.
      _transport.releaseStreamId(_streamId);
      rethrow;
    }
  }

  /// The call scope managing this processor's resources.
  RpcCallScope get scope => _scope;

  /// Incoming responses from server.
  Stream<RpcMessage<TResponse>> get responses => _responseController.stream;

  /// Whether processor is active.
  bool get isActive => _isActive;

  /// Stream ID.
  int get streamId => _streamId;

  /// Zero-copy mode flag.
  bool get isZeroCopy => _isZeroCopy;

  /// Configures outgoing request handling.
  ///
  /// The actual transmission is queued synchronously by [send] onto
  /// [_sendSequence]; this listener only consumes the controller stream. When
  /// the controller is closed via [finishSending], `onDone` awaits
  /// [_sendSequence] before calling the transport's finishSending, guaranteeing
  /// every queued request was sent first (the last request is never dropped).
  void _setupRequestHandler() {
    _scope.listen<TRequest>(
      _requestController.stream,
      (request) {
        // No-op: transmission is queued synchronously in send().
      },
      onDone: () async {
        if (!_isActive) return;

        try {
          // Wait for any pending request sends to complete before finishing.
          await _sendSequence;
          await _transport.finishSending(_streamId);
          _logger.internal(
            'finishSending completed for $_methodPath [streamId: $_streamId]',
          );
        } catch (e, stackTrace) {
          _logger.error(
            'Failed to finish sending requests [streamId: $_streamId]',
            error: e,
            stackTrace: stackTrace,
          );
        }
      },
      onError: (error, stackTrace) {
        _logger.error(
          'Error in request stream for $_methodPath [streamId: $_streamId]',
          error: error,
          stackTrace: stackTrace,
        );
        if (!_responseController.isClosed) {
          _responseController.addError(error, stackTrace);
        }
      },
    );
  }

  /// Queues the transmission of [request] onto [_sendSequence].
  ///
  /// Called synchronously from [send] so that a subsequent [finishSending]
  /// (which closes the request controller; its `onDone` awaits [_sendSequence])
  /// always observes the queued write and never drops the last request.
  void _transmitRequest(TRequest request) {
    _sendSequence = _sendSequence.then((_) async {
      if (!_isActive) return;

      try {
        // Send initial metadata with the first request.
        if (!_initialMetadataSent) {
          await _sendInitialMetadata();
          _initialMetadataSent = true;
        }

        _logger.internal(
          'Sending request for $_methodPath [streamId: $_streamId]',
        );

        if (_isZeroCopy) {
          // Zero-copy path.
          if (_logger.isInternal) {
            _logger.internal('Zero-copy request send [streamId: $_streamId]');
          }
          await _transport.sendDirectObject(_streamId, request);
          if (_logger.isInternal) {
            _logger.internal(
              'Zero-copy request sent for $_methodPath [streamId: $_streamId]',
            );
          }
        } else {
          // Serialization for network transports.
          final serialized = _requestCodec!.serialize(request);
          if (_logger.isInternal) {
            _logger.internal(
              'Request serialized (${serialized.length} bytes) [streamId: $_streamId]',
            );
          }

          final requestEncoding = _context?.getHeader(RpcHeaders.grpcEncoding);
          if (requestEncoding != null &&
              requestEncoding != RpcGrpcCompression.identity &&
              !RpcGrpcCompression.isSupported(requestEncoding)) {
            throw RpcException(
              'Unsupported grpc-encoding: $requestEncoding. '
              'Supported: ${RpcGrpcCompression.supportedEncodings().join(', ')}. '
              'On web/dart2js the built-in gzip is unavailable; register a '
              'cross-platform codec (e.g. RpcGzipCodec.register() from '
              'package:rpc_dart_compression).',
            );
          }
          await _frameAndSend(
            _transport,
            _streamId,
            serialized,
            requestEncoding,
          );

          _logger.internal(
            'Request sent for $_methodPath [streamId: $_streamId]',
          );
        }
      } catch (e, stackTrace) {
        _logger.error(
          'Failed to send request [streamId: $_streamId]',
          error: e,
          stackTrace: stackTrace,
        );
        if (!_responseController.isClosed) {
          _responseController.addError(e, stackTrace);
        }

        // Critical: on routing error stop immediately to prevent further sends.
        if (!_requestController.isClosed) {
          _requestController.close();
        }
      }
    });
  }

  /// Configures incoming response handling.
  void _setupResponseHandler() {
    _scope.listen<RpcTransportMessage>(
      _transport.getMessagesForStream(_streamId),
      _handleResponse,
      onError: (error, stackTrace) {
        _logger.error(
          'Error in response stream',
          error: error,
          stackTrace: stackTrace,
        );
        if (!_responseController.isClosed) {
          _responseController.addError(error, stackTrace);
        }
      },
      onDone: () {
        _logger.internal(
          'Response stream completed for $_methodPath [streamId: $_streamId]',
        );
        if (!_responseController.isClosed) {
          _responseController.close();
        }
      },
    );
  }

  /// Sends initial metadata with context support.
  Future<void> _sendInitialMetadata() async {
    _logger.internal(
      'Sending initial metadata for $_methodPath [streamId: $_streamId]',
    );

    final baseMetadata = RpcMetadata.forClientRequest(
      _serviceName,
      _methodName,
    );

    // Use a map so context headers naturally override base headers,
    // preventing duplicates (e.g. grpc-accept-encoding).
    final headerMap = <String, String>{
      for (final h in baseMetadata.headers) h.name: h.value,
    };

    if (_context != null) {
      // User metadata must not clobber protocol-reserved headers.
      for (final entry in _context.headers.entries) {
        if (RpcHeaders.isReserved(entry.key)) continue;
        headerMap[entry.key] = entry.value;
      }

      if (_context.traceId != null) {
        headerMap[RpcHeaders.xTraceId] = _context.traceId!;
      }
      headerMap[RpcHeaders.xRequestId] = _context.requestId;

      if (_context.deadline != null) {
        final timeout = _context.remainingTime;
        if (timeout != null) {
          headerMap[RpcHeaders.grpcTimeout] = RpcMetadata.encodeGrpcTimeout(
            timeout,
          );
        }
      }

      _logger.internal(
        'Context headers added: ${_context.headers.length} custom + system [streamId: $_streamId]',
      );
    } else {
      headerMap[RpcHeaders.xRequestId] = RpcContext.empty().requestId;

      _logger.internal(
        'Added base request-id for null context [streamId: $_streamId]',
      );
    }

    final metadata = RpcMetadata([
      for (final e in headerMap.entries) RpcHeader(e.key, e.value),
    ], methodPath: baseMetadata.methodPath);
    await _transport.sendMetadata(_streamId, metadata);

    _logger.internal(
      'Initial metadata sent for $_methodPath [streamId: $_streamId]',
    );
  }

  /// Surfaces deadline expiry as an error on the response stream.
  ///
  /// [RpcCallScope] already closes itself when the context deadline fires, and
  /// that closes the response controller — but a bare close is indistinguishable
  /// from the server having finished. A server-stream call therefore ended
  /// *normally* on deadline expiry, handing the consumer a silently truncated
  /// stream, and a client-stream call reported UNAVAILABLE ("Stream closed
  /// without receiving response") rather than the deadline it actually hit.
  ///
  /// This disposer is registered AFTER the one that closes the controllers, so
  /// LIFO ordering runs it FIRST — the error reaches the stream while it is
  /// still open. It fires only when the scope closed on its own (`_isActive`
  /// still true, so not an explicit [close]) and the deadline really has
  /// passed, which excludes cancellation and normal completion.
  void _setupDeadlineMonitoring() {
    final context = _context;
    final deadline = context?.deadline;
    if (deadline == null) return;

    _scope.onDispose(() {
      if (!_isActive) return;
      if (!context!.isExpired) return;

      _logger.internal('Deadline exceeded [streamId: $_streamId]');
      final error = RpcDeadlineExceededException(deadline, Duration.zero);
      // Single-subscription controllers buffer the error for a late
      // subscriber, so do not gate on hasListener.
      if (!_responseController.isClosed) _responseController.addError(error);
      if (!_requestController.isClosed) _requestController.addError(error);
    });
  }

  /// Sets up cancellation monitoring via the call scope.
  void _setupCancellationMonitoring() {
    if (_context?.cancellationToken == null) return;

    _scope.listen<void>(
      _context!.cancellationToken!.cancelled.asStream(),
      (_) async {
        _logger.internal(
          'Operation cancelled by client, notifying server [streamId: $_streamId]',
        );

        try {
          final reason =
              _context.cancellationToken!.reason ??
              'Operation cancelled by client';
          await _sendCancellationToServer(reason);
        } catch (e, stackTrace) {
          _logger.error(
            'Failed to send cancellation notice [streamId: $_streamId]',
            error: e,
            stackTrace: stackTrace,
          );
        }

        _isActive = false;
        final cancelledException = RpcCancelledException(
          _context.cancellationToken!.reason ?? 'Operation was cancelled',
        );

        try {
          // Single-subscription controller: addError buffers the error for a
          // late subscriber. Do NOT gate on hasListener — that would drop the
          // cancellation if it fires before the consumer subscribes.
          if (!_requestController.isClosed) {
            _requestController.addError(cancelledException);
          }
        } catch (e) {
          _logger.warning(
            'Failed to deliver cancellation to request stream [streamId: $_streamId]',
            error: e,
          );
        }
        try {
          // Single-subscription controller: addError buffers the error for a
          // late subscriber. Do NOT gate on hasListener — that would drop the
          // cancellation if it fires before the consumer subscribes.
          if (!_responseController.isClosed) {
            _responseController.addError(cancelledException);
          }
        } catch (e) {
          _logger.warning(
            'Failed to deliver cancellation to response stream [streamId: $_streamId]',
            error: e,
          );
        }
      },
      onError: (error, stackTrace) {
        _logger.error(
          'Error monitoring cancellation [streamId: $_streamId]',
          error: error,
          stackTrace: stackTrace,
        );
      },
    );
  }

  /// Sends a cancellation notice to the server.
  Future<void> _sendCancellationToServer(String reason) =>
      _notifyPeerOfCancellation(_transport, _streamId, reason, _logger);

  /// Validates context before making the call.
  void _checkContextBeforeCall() {
    if (_context == null) return;

    // Check cancellation.
    _context.cancellationToken?.throwIfCancelled();

    // Check deadline.
    if (_context.isExpired) {
      throw RpcDeadlineExceededException(_context.deadline!, Duration.zero);
    }

    _logger.internal(
      'Context verified: requestId=${_context.requestId}, traceId=${_context.traceId} [streamId: $_streamId]',
    );
  }

  /// Handles an incoming response.
  void _handleResponse(RpcTransportMessage message) {
    if (!_isActive) return;

    if (_logger.isInternal) {
      _logger.internal(
        'Handling response [streamId: ${message.streamId}, isMetadataOnly: ${message.isMetadataOnly}, hasPayload: ${message.payload != null}, isDirect: ${message.isDirect}]',
      );
    }

    try {
      // Handle metadata.
      if (message.isMetadataOnly) {
        final encoding = message.metadata?.getHeaderValue(
          RpcHeaders.grpcEncoding,
        );
        if (encoding != null) {
          _peerGrpcEncoding = encoding;
        }

        final rpcMessage = RpcMessage.withMetadata<TResponse>(
          message.metadata!,
          isEndOfStream: message.isEndOfStream,
        );

        if (!_responseController.isClosed) {
          _responseController.add(rpcMessage);
          _logger.internal(
            'Metadata pushed to response stream [streamId: $_streamId]',
          );
        }
      }

      // Zero-copy: process direct object.
      if (message.isDirect && message.directPayload != null) {
        _processDirectResponse(message.directPayload!);
      }
      // Handle serialized payload.
      else if (!message.isMetadataOnly && message.payload != null) {
        _processResponseData(message.payload!);
      }

      // Finish stream on END_STREAM.
      if (message.isEndOfStream) {
        _logger.internal(
          'END_STREAM received, closing response stream [streamId: $_streamId]',
        );
        if (!_responseController.isClosed) {
          _responseController.close();
        }
      }
    } catch (e, stackTrace) {
      _logger.error(
        'Failed to process response [streamId: $_streamId]',
        error: e,
        stackTrace: stackTrace,
      );
      if (!_responseController.isClosed) {
        _responseController.addError(e, stackTrace);
      }
    }
  }

  /// Zero-copy: handles a direct response object without serialization.
  void _processDirectResponse(Object directPayload) {
    if (_logger.isInternal) {
      _logger.internal(
        'Zero-copy response handling [streamId: $_streamId, type: ${directPayload.runtimeType}]',
      );
    }

    try {
      final response = directPayload as TResponse;
      final rpcMessage = RpcMessage.withPayload<TResponse>(response);

      if (!_responseController.isClosed) {
        _responseController.add(rpcMessage);
        _logger.internal(
          'Zero-copy response added to response stream [streamId: $_streamId]',
        );
      } else {
        _logger.warning(
          'Zero-copy: cannot add response to closed controller [streamId: $_streamId]',
        );
      }
    } catch (e, stackTrace) {
      _logger.error(
        'Zero-copy direct response handling error [streamId: $_streamId]',
        error: e,
        stackTrace: stackTrace,
      );
      if (!_responseController.isClosed) {
        _responseController.addError(e, stackTrace);
      }
    }
  }

  /// Processes response data (serialization mode only).
  void _processResponseData(List<int> messageBytes) {
    if (_isZeroCopy) {
      _logger.warning(
        'Serialized response received in zero-copy mode, ignoring [methodPath: $_methodPath, streamId: $_streamId]',
      );
      return;
    }

    if (_logger.isInternal) {
      _logger.internal(
        'Received response payload: ${messageBytes.length} bytes [streamId: $_streamId]',
      );
    }

    try {
      final uint8Message = messageBytes is Uint8List
          ? messageBytes
          : Uint8List.fromList(messageBytes);

      final messages = _parser!(uint8Message);
      if (_logger.isInternal) {
        _logger.internal(
          'Parser extracted ${messages.length} messages from frame [streamId: $_streamId]',
        );
      }

      for (var msgBytes in messages) {
        try {
          if (_logger.isInternal) {
            _logger.internal(
              'Deserializing response of ${msgBytes.length} bytes [streamId: $_streamId]',
            );
          }
          final response = _responseCodec!.deserialize(msgBytes);

          final rpcMessage = RpcMessage.withPayload<TResponse>(response);

          if (!_responseController.isClosed) {
            _responseController.add(rpcMessage);
            _logger.internal(
              'Deserialized response added to stream [streamId: $_streamId]',
            );
          } else {
            _logger.warning(
              'Cannot add response to closed controller [streamId: $_streamId]',
            );
          }
        } catch (e, stackTrace) {
          _logger.error(
            'Failed to deserialize response [streamId: $_streamId]',
            error: e,
            stackTrace: stackTrace,
          );
          if (!_responseController.isClosed) {
            _responseController.addError(e, stackTrace);
          }
        }
      }
    } catch (e, stackTrace) {
      _logger.error(
        'Failed to parse response [streamId: $_streamId]',
        error: e,
        stackTrace: stackTrace,
      );
      if (!_responseController.isClosed) {
        _responseController.addError(e, stackTrace);
      }
    }
  }

  /// Sends a request to the server.
  Future<void> send(TRequest request) async {
    if (!_isActive) {
      _logger.warning('Attempted to send request on inactive processor');
      return;
    }

    if (!_requestController.isClosed) {
      // Queue the transmission synchronously so a subsequent finishSending()
      // (which closes the controller; its onDone awaits _sendSequence) always
      // observes this write. Also forward to the controller so its stream keeps
      // draining and onDone fires after the queued send.
      _transmitRequest(request);
      _requestController.add(request);
    } else {
      _logger.warning('Attempted to send request to closed controller');
    }
  }

  /// Finishes sending requests.
  Future<void> finishSending() async {
    if (!_isActive) return;

    _logger.internal(
      'Finishing request send for $_methodPath [streamId: $_streamId]',
    );

    // A client stream may legitimately carry ZERO messages, and gRPC expects
    // that to open the call anyway: HEADERS, then end-of-stream. The initial
    // metadata was only ever sent by _transmitRequest, so a call that sent no
    // request never announced itself at all -- no method path reached the
    // responder, no handler ran, and the caller waited out its own timeout on
    // a server that had no idea the call existed.
    _queueInitialMetadataIfUnsent();

    if (!_requestController.isClosed) {
      await _requestController.close();
    }
  }

  /// Queues the initial metadata onto [_sendSequence] if it has not gone out.
  ///
  /// Queued rather than sent directly so it keeps its place ahead of anything
  /// already pending, and so the request handler's `onDone` (which awaits
  /// [_sendSequence] before calling the transport's finishSending) observes it.
  void _queueInitialMetadataIfUnsent() {
    if (_initialMetadataSent) return;
    _sendSequence = _sendSequence.then((_) async {
      if (!_isActive || _initialMetadataSent) return;
      try {
        await _sendInitialMetadata();
        _initialMetadataSent = true;
      } catch (e, stackTrace) {
        if (_isTransportClosed(e)) return;
        _logger.error(
          'Failed to send initial metadata [streamId: $_streamId]',
          error: e,
          stackTrace: stackTrace,
        );
        if (!_responseController.isClosed) {
          _responseController.addError(e, stackTrace);
        }
      }
    });
  }

  /// Closes the processor and releases resources.
  ///
  /// Delegates to [RpcCallScope.close] which runs all registered
  /// disposers (subscriptions, controllers) in reverse order.
  Future<void> close() async {
    if (!_isActive) return;

    _logger.internal(
      'Closing CallProcessor for $_methodPath [streamId: $_streamId]',
    );
    _isActive = false;

    await _scope.close();
  }
}
