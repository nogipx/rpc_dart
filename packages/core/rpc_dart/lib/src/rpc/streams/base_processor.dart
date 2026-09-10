// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

part of '_index.dart';

/// Returns true if [error] indicates the underlying transport is closed.
///
/// Network transports signal this with `StateError('Transport is closed')`.
/// Matched on exact type and message rather than a broad
/// `toString().contains('closed')`, which would swallow unrelated errors whose
/// text merely mentions "closed".
bool _isTransportClosed(Object error) {
  return error is StateError && error.message == 'Transport is closed';
}

/// Compresses [serialized] with [encoding] (null or `identity` = no
/// compression), wraps it in the gRPC 5-byte frame, and sends it on [streamId].
///
/// [encoding] must already be resolved and validated by the caller.
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

/// The [RpcSecurityPolicy] [transport] was configured with, or the defaults.
///
/// Every parser must be built from this rather than from [RpcMessageParser]'s
/// own defaults. For an uncompressed message the two agree, because the channel
/// bounds the frame payload by the same policy before the parser sees it. For a
/// COMPRESSED payload they do not: the channel bounds the compressed bytes and
/// the expansion is bounded here alone, so a parser left on the defaults
/// enforces their hard-coded 64MB ceiling instead of the operator's policy --
/// wrong in both directions, since a tighter policy is then not applied and a
/// looser one is silently capped.
RpcSecurityPolicy _policyOf(IRpcTransport transport) =>
    transport is IRpcSecurityPolicyAware
    ? (transport as IRpcSecurityPolicyAware).securityPolicy
    : const RpcSecurityPolicy();

/// Builds a parser bounded by [transport]'s policy rather than by
/// [RpcMessageParser]'s defaults. See [_policyOf].
RpcMessageParser _policyBoundParser({
  required IRpcTransport transport,
  required LogScope logger,
  required Uint8List Function(Uint8List payload, {int? maxOutputBytes})
  decompressor,
}) {
  final policy = _policyOf(transport);
  return RpcMessageParser(
    logger: logger,
    maxMessageLength: policy.maxMessageLengthBytes,
    maxBufferedBytes: policy.effectiveMaxBufferedBytes,
    maxMessagesPerChunk: policy.maxMessagesPerChunk,
    decompressor: decompressor,
  );
}

/// Tells the peer that [streamId] was cancelled, so its handler can stop.
///
/// Prefers a transport-level reset: the metadata fallback rides a frame with
/// `endStream: true`, legal only while this side is still open, and by
/// cancellation time it usually is not (every caller here half-closes once its
/// request is sent). HTTP/2 throws that violation asynchronously out of its
/// stream handler and corrupts the connection.
///
/// Never throws: a courtesy to the peer must not turn a cancelled call into a
/// failed teardown.
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

/// Answers a peer whose payload SHAPE does not match this side's transfer mode.
///
/// The two ends pick their mode from their OWN contract, so they can disagree:
/// a caller in [RpcDataTransferMode.codec] sends bytes to a method registered
/// zero-copy, which reads `directPayload` and finds none. Both sites must
/// ANSWER. Logging and returning left the peer with no reply at all until its
/// own deadline.
///
/// An [RpcException] because it is a library diagnostic with no user data in
/// it, so `wireStatusFor` forwards the text to the peer -- the side that can
/// fix it.
void _reportTransferModeMismatch(
  StreamController<dynamic> controller,
  LogScope logger,
  String methodPath,
  int streamId,
  String direction,
) {
  final error = RpcException(
    'Transfer-mode mismatch on $methodPath: a serialized $direction arrived '
    'for a method registered as zero-copy. Both ends take the mode from their '
    'own contract, so give them the same RpcDataTransferMode (or codecs on '
    'both sides).',
  );
  logger.error(
    'transfer_mode_mismatch [methodPath: $methodPath, streamId: $streamId]',
    error: error,
  );
  if (!controller.isClosed) controller.addError(error, StackTrace.current);
}

/// Responder side of one call: feeds requests to the handler, puts its
/// responses, errors and trailer on the wire.
///
/// Zero-copy when both codecs are null (needs a zero-copy transport),
/// serialized otherwise.
final class StreamProcessor<TRequest extends Object, TResponse extends Object> {
  final LogScope _logger;
  final IRpcTransport _transport;
  final int _streamId;
  final String _serviceName;
  final String _methodName;
  final IRpcCodec<TRequest>? _requestCodec;
  final IRpcCodec<TResponse>? _responseCodec;

  final RpcContext? _context;
  final RpcCallScope _scope;

  /// Reassembles fragmented frames. Null in zero-copy mode.
  RpcMessageParser? _parser;

  final bool _isZeroCopy;

  final StreamController<TRequest> _requestController =
      StreamController<TRequest>();
  final StreamController<TResponse> _responseController =
      StreamController<TResponse>();

  /// Serialises the send path: each write chains onto the previous one, so
  /// order is preserved and the trailer can wait for every response to leave.
  Future<void> _sendSequence = Future<void>.value();

  bool _trailerSent = false;

  /// First response that could not be put on the wire, if any.
  ///
  /// A response the peer never received must not be reported as a successful
  /// call: [finishSending] answers with this instead of grpc-status 0.
  Object? _responseSendFailure;

  bool _isActive = true;
  bool _initialMetadataSent = false;

  /// Encoding for responses, picked from the peer's grpc-accept-encoding; null
  /// means identity. Seeded from the server context, then overridden by the
  /// peer's initial metadata when it arrives.
  String? _responseEncoding;

  /// Encoding the peer advertised in grpc-encoding, read by the decompressor.
  String? _requestEncoding;

  /// `/Service/Method`.
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
    if (!_isZeroCopy) {
      if (_requestCodec == null || _responseCodec == null) {
        throw ArgumentError(
          'Codecs are required for serialization mode. '
          'For zero-copy leave codecs null.',
        );
      }
      _parser = _policyBoundParser(
        transport: transport,
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

  /// Consumes the response controller so errors pushed onto it are observed.
  ///
  /// Data events are ignored on purpose: [send] queues transmission onto
  /// [_sendSequence] synchronously, and queuing from this listener instead
  /// would race with [sendError]/[finishSending], which await [_sendSequence]
  /// and could close the controller before the last message was queued.
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
          // Only sent when there is compression to advertise. Streaming
          // otherwise emits no initial metadata at all, and in-memory
          // transports rely on that.
          if (_responseEncoding != null && !_initialMetadataSent) {
            await _transport.sendMetadata(
              _streamId,
              RpcMetadata.forServerInitialResponse(encoding: _responseEncoding),
            );
            _initialMetadataSent = true;
          }

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
        // Anything else here is a genuine delivery failure -- an unsendable
        // object, a codec or compressor that threw. Recording it is what stops
        // finishSending answering grpc-status 0 for a response the peer never
        // received, which reads as a stream that simply did not contain it.
        _responseSendFailure ??= e;
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

    final subscription = _scope.listen<RpcTransportMessage>(
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

    // Responder half of the demand chain, mirroring CallProcessor's caller-side
    // hook. The handler consumes _requestController; without these the bound
    // message stream is drained at full speed regardless, so a slow handler
    // never throttles the peer.
    //
    // It starts PAUSED, and that is the load-bearing part. NO SUBSCRIBER IS
    // ALSO NO DEMAND: resuming unconditionally covers only a handler that has
    // already subscribed and then pauses, but every handler has no subscriber
    // during an async prelude, and `await auth(); await for (requests)` is
    // ordinary code. Starting paused makes "not yet listening" behave like
    // "listening and paused", so the peer parks on the window instead of
    // pushing its whole payload into responder memory.
    //
    // This cannot deadlock: a handler that never reads is still free to return
    // a response at any time, which completes the call. Only the peer's
    // SENDING is throttled, and the alternative is unbounded memory.
    _requestController.onListen = () => subscription.resume();
    _requestController.onPause = () => subscription.pause();
    _requestController.onResume = () => subscription.resume();
    if (_requestController.hasListener) {
      // Already subscribed before the bind: onListen will not fire again.
      subscription.resume();
    } else {
      subscription.pause();
    }

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

    if (message.isDirect && message.directPayload != null) {
      _processDirectMessage(message.directPayload!);
    } else if (!message.isMetadataOnly && message.payload != null) {
      _processDataMessage(message.payload!);
    }

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
      // Answered, not dropped -- see _reportTransferModeMismatch. The mirror
      // direction never had this problem: a direct object arriving at a
      // serialized processor is cast to TRequest and delivered, which is how a
      // zero-copy caller talks to a codec-declared responder.
      _reportTransferModeMismatch(
        _requestController,
        _logger,
        _methodPath,
        _streamId,
        'request',
      );
      return;
    }

    _logger.internal(
      'Message received [streamId: $_streamId, type: serialized_data, size: ${messageBytes.length}]',
    );

    try {
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

    try {
      _checkCancellation();
    } catch (e) {
      _logger.internal(
        'Response skipped due to cancellation [streamId: $_streamId]',
      );
      return;
    }

    if (!_responseController.isClosed) {
      // Queue synchronously so a later sendError()/finishSending() awaiting
      // _sendSequence always observes this write; forward to the controller so
      // its stream keeps draining and errors on it are observed.
      _transmitResponse(response);
      _responseController.add(response);
      // Then WAIT for it to leave. The queue is what preserves ordering;
      // awaiting it here is what keeps the queue depth at one. Returning as
      // soon as the write was enqueued turned _sendSequence into an unbounded
      // buffer between handler and transport, defeating the `await send(...)`
      // the server-stream pump uses to let a slow transport throttle the
      // handler.
      await _sendSequence;
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
      // With no initial metadata this becomes a Trailers-Only response; the
      // transport adds :status: 200 for that case and tells the two apart by
      // whether initial headers went out. Both carry the same grpc-status and
      // optional grpc-message.
      if (!_initialMetadataSent) {
        _logger.internal('Sending Trailers-Only error [streamId: $_streamId]');
        _initialMetadataSent = true;
      }

      // Trimmed to the policy the trailer will itself be validated against: a
      // refusal's own answer must satisfy the rule that refused, and
      // `grpc-message` is a header value like any other. Untrimmed, an
      // over-long message turned the handler's status into a generic internal
      // error, or into silence. The STATUS must survive; the text gives way.
      final trailers = RpcMetadata.forTrailer(
        statusCode,
        message: message,
        statusDetailsBin: statusDetailsBin,
        maxMessageLength: _policyOf(_transport).maxHeaderValueBytes,
      );
      await _transport.sendMetadata(_streamId, trailers, endStream: true);

      _logger.internal('Error sent to client [streamId: $_streamId]');
      _trailerSent = true;
    } catch (e, stackTrace) {
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

    // Whatever this method decides below, the call gets ONE terminal frame.
    // `_sendOkTrailerIfNeeded` guards on this; the failure branch calls
    // `sendError` directly, which does not -- so an already-answered stream
    // would take a second grpc-status, a protocol violation on any transport
    // with real stream state.
    if (_trailerSent) return;

    // A response that never reached the peer makes this call a failure,
    // whatever the handler thinks. Routed through wireStatusFor so the cause
    // stays on the server; it is already logged at the failure site.
    final failure = _responseSendFailure;
    if (failure != null) {
      final wire = wireStatusFor(failure);
      await sendError(
        wire.status,
        wire.message,
        statusDetailsBin: wire.detailsBin,
      );
      return;
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

  /// Pushes an [RpcCancelledException] into both controllers on cancellation.
  ///
  /// The scope auto-closes on cancellation and deadline, but a close alone
  /// leaves the handler unable to tell a cancelled call from a finished one.
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

        // Both are single-subscription controllers, so addError buffers for a
        // late subscriber. Do NOT gate either on hasListener -- that drops the
        // cancellation when it fires before the consumer subscribes.
        try {
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

/// Caller side of one call: sends requests, surfaces responses, and owns the
/// stream id, the deadline and the cancellation wiring.
///
/// Zero-copy when both codecs are null (needs a zero-copy transport),
/// serialized otherwise.
final class CallProcessor<TRequest extends Object, TResponse extends Object> {
  final LogScope _logger;
  final IRpcTransport _transport;
  final int _streamId;
  final String _serviceName;
  final String _methodName;
  final IRpcCodec<TRequest>? _requestCodec;
  final IRpcCodec<TResponse>? _responseCodec;

  final RpcContext? _context;
  final RpcCallScope _scope;

  /// Reassembles fragmented frames. Null in zero-copy mode.
  RpcMessageParser? _parser;

  /// Encoding the peer advertised in grpc-encoding, read by the decompressor.
  String? _peerGrpcEncoding;

  final bool _isZeroCopy;

  final StreamController<TRequest> _requestController =
      StreamController<TRequest>();
  final StreamController<RpcMessage<TResponse>> _responseController =
      StreamController<RpcMessage<TResponse>>();

  /// Serialises the send path: each write chains onto the previous one, so
  /// order is preserved and the half-close waits for every request to leave.
  Future<void> _sendSequence = Future<void>.value();

  bool _isActive = true;
  bool _initialMetadataSent = false;

  /// `/Service/Method`.
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
      if (!_isZeroCopy) {
        if (_requestCodec == null || _responseCodec == null) {
          throw ArgumentError(
            'Codecs are required for serialization mode. '
            'For zero-copy leave codecs null.',
          );
        }
        _parser = _policyBoundParser(
          transport: transport,
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

      _scope.onDispose(() {
        // Free the stream id so an aborted call (cancellation, deadline, error)
        // releases its slot. The normal path releases it too; releaseStreamId
        // is idempotent.
        _transport.releaseStreamId(_streamId);
        if (!_requestController.isClosed) _requestController.close();
        if (!_responseController.isClosed) _responseController.close();
      });

      _checkContextBeforeCall();

      _setupDeadlineMonitoring();
      _setupCancellationMonitoring();
      _setupRequestHandler();
      _setupResponseHandler();
    } catch (_) {
      // createStream() ran in the initializer list, so a throw in the body
      // hands the caller no instance and close() never runs. Without this the
      // allocated stream id leaks.
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

  /// Consumes the request controller and half-closes the stream after it.
  ///
  /// Data events are ignored: [send] queues transmission onto [_sendSequence]
  /// synchronously. `onDone` awaits that queue before the transport's
  /// finishSending, so the last request is never dropped.
  void _setupRequestHandler() {
    _scope.listen<TRequest>(
      _requestController.stream,
      (request) {
        // No-op: transmission is queued synchronously in send().
      },
      onDone: () async {
        if (!_isActive) return;

        try {
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
        if (!_initialMetadataSent) {
          await _sendInitialMetadata();
          _initialMetadataSent = true;
        }

        _logger.internal(
          'Sending request for $_methodPath [streamId: $_streamId]',
        );

        if (_isZeroCopy) {
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

        // Close on the first send failure: the stream is no longer coherent,
        // so further sends would put a gapped request sequence on the wire.
        if (!_requestController.isClosed) {
          _requestController.close();
        }
      }
    });
  }

  /// Configures incoming response handling.
  void _setupResponseHandler() {
    final subscription = _scope.listen<RpcTransportMessage>(
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
          // Our own deadline is authoritative over a bare close: the peer ends
          // its stream on the same deadline, closing this one at almost the
          // same instant, and a bare close is indistinguishable from the server
          // having finished. Which of the two the consumer saw was a race.
          //
          // Tested with remainingTime, NOT isExpired. isExpired is
          // `clock().isAfter(deadline)` -- strict -- so it is false at the
          // instant the deadline lands, while remainingTime is already zero,
          // and that boundary is exactly where the peer's close arrives.
          final deadline = _context?.deadline;
          if (deadline != null && _context?.remainingTime == Duration.zero) {
            _responseController.addError(
              RpcDeadlineExceededException(deadline, Duration.zero),
            );
          } else {
            // Still OPEN here means the stream ended with no end-of-stream
            // message: a normal finish, an error trailer, a cancellation and a
            // deadline all close it before now. So the transport went away
            // mid-call, and gRPC calls a stream that ends without a trailer
            // UNAVAILABLE. Closing silently instead let a server-stream or bidi
            // consumer read a truncated result as a complete one.
            _responseController.addError(
              RpcStatusException(
                RpcStatus.unavailable,
                'Stream closed before the server completed the call',
              ),
            );
          }
          _responseController.close();
        }
      },
    );

    // Caller half of the demand chain. Without it the transport subscription
    // keeps feeding this controller after every stage above has stopped
    // pulling, so a paused consumer still pays to decode every message; pausing
    // here leaves the frames undecoded in the transport's per-stream buffer.
    _responseController.onPause = () => subscription.pause();
    _responseController.onResume = () => subscription.resume();
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

    // A map, so context headers override base headers rather than duplicating
    // them (e.g. grpc-accept-encoding).
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
  /// [RpcCallScope] closes itself when the deadline fires, and a bare close is
  /// indistinguishable from the server having finished: a server-stream call
  /// then ends *normally* on expiry, handing the consumer a truncated stream.
  /// Registered AFTER the disposer that closes the controllers, so LIFO runs it
  /// FIRST and the error reaches the stream while it is still open.
  ///
  /// Reaching here means the deadline timer fired. The scope self-closes for
  /// exactly two reasons; `_isActive` still true rules out an explicit [close],
  /// and cancellation is surfaced by [_setupCancellationMonitoring].
  ///
  /// Do NOT re-derive that from the clock. `context.isExpired` is
  /// `clock().isAfter(deadline)` -- STRICT -- while the scope's timer is armed
  /// for `deadline.difference(clock())`, and Timer and DateTime do not share a
  /// clock source, so on firing `now` can be a hair short of the deadline.
  /// Guarding on it made this disposer return and the controllers close with no
  /// error at all -- the exact failure it exists to prevent, as an intermittent
  /// flake under load.
  void _setupDeadlineMonitoring() {
    final context = _context;
    final deadline = context?.deadline;
    if (deadline == null) return;

    _scope.onDispose(() {
      if (!_isActive) return;
      if (context!.isCancelled) return;

      _logger.internal('Deadline exceeded [streamId: $_streamId]');
      final error = RpcDeadlineExceededException(deadline, Duration.zero);
      // Single-subscription controllers buffer the error for a late
      // subscriber, so do not gate on hasListener.
      if (!_responseController.isClosed) _responseController.addError(error);
      if (!_requestController.isClosed) _requestController.addError(error);
    });
  }

  /// Pushes an [RpcCancelledException] into both controllers on cancellation,
  /// and tells the peer.
  void _setupCancellationMonitoring() {
    if (_context?.cancellationToken == null) return;

    _scope.listen<void>(
      _context!.cancellationToken!.cancelled.asStream(),
      (_) async {
        _logger.internal(
          'Operation cancelled by client, notifying server [streamId: $_streamId]',
        );

        _isActive = false;
        final cancelledException = RpcCancelledException(
          _context.cancellationToken!.reason ?? 'Operation was cancelled',
        );

        // Telling the SERVER is best-effort and must not gate telling OUR OWN
        // consumer: the cancellation is a local fact, the notice is a network
        // round trip. Awaiting the notice first meant a send that never
        // completed took the local error with it -- and the `try` below catches
        // a throw, not a hang. Only a transport whose send awaits a platform
        // reply can hang that way, and the consumer then saw a clean DONE,
        // indistinguishable from a stream that finished.
        unawaited(
          _sendCancellationToServer(
            _context.cancellationToken!.reason ??
                'Operation cancelled by client',
          ).catchError((Object e, StackTrace stackTrace) {
            _logger.error(
              'Failed to send cancellation notice [streamId: $_streamId]',
              error: e,
              stackTrace: stackTrace,
            );
          }),
        );

        // Both are single-subscription controllers, so addError buffers for a
        // late subscriber. Do NOT gate either on hasListener -- that drops the
        // cancellation when it fires before the consumer subscribes.
        try {
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

  /// Tells the peer this call is being abandoned locally, so its handler stops.
  ///
  /// [_sendCancellationToServer] is reachable only through a cancellation
  /// token, so a call that ends because its local REQUEST STREAM failed has no
  /// way to reach it: the caller tears itself down and the peer is never told.
  /// Its handler then sits in `await for (requests)` forever, holding a
  /// responder-state entry and a transport stream controller -- and
  /// `activeStreams` stays 0 throughout, so `maxActiveStreams` never notices
  /// and the growth is unbounded.
  ///
  /// Never throws (see [_notifyPeerOfCancellation]).
  Future<void> notifyPeerOfAbort(String reason) =>
      _sendCancellationToServer(reason);

  /// Refuses a call whose context is already cancelled or expired.
  void _checkContextBeforeCall() {
    if (_context == null) return;

    _context.cancellationToken?.throwIfCancelled();

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

      if (message.isDirect && message.directPayload != null) {
        _processDirectResponse(message.directPayload!);
      } else if (!message.isMetadataOnly && message.payload != null) {
        _processResponseData(message.payload!);
      }

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
      // Answered, not dropped -- see _reportTransferModeMismatch.
      _reportTransferModeMismatch(
        _responseController,
        _logger,
        _methodPath,
        _streamId,
        'response',
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
      // Queue synchronously so finishSending() -- which closes the controller,
      // and whose onDone awaits _sendSequence -- always observes this write;
      // forward to the controller so its stream keeps draining and onDone fires
      // after the queued send.
      _transmitRequest(request);
      _requestController.add(request);
      // Then WAIT for it to leave, exactly as the response side does.
      // Otherwise _sendSequence is an unbounded buffer between the request pump
      // and the transport, and the `await caller.send(req)` the pump uses to
      // let a blocked transport throttle the producer does nothing.
      await _sendSequence;
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
    // that to open the call anyway: HEADERS, then end-of-stream. Initial
    // metadata is otherwise sent only by _transmitRequest, so a call that sent
    // no request never announces itself -- no method path reaches the
    // responder, and the caller waits out its own timeout against a server that
    // does not know the call exists.
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
