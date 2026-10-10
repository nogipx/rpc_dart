// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

part of '_index.dart';

/// Returns true if [error] indicates the underlying transport is closed.
///
/// One TYPE check. This used to compare the exception's MESSAGE text against a
/// literal, in two spellings, because the transports disagreed on which to
/// throw — so the wording was a contract that nothing declared and the compiler
/// could not check.
bool _isTransportClosed(Object error) => error is RpcClosedException;

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
  final (payload, useCompression) = RpcGrpcCompression.compressIfSmaller(
    serialized,
    encoding: encoding,
  );
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
  // INTERNAL: the two ends were configured with different transfer modes, which
  // is a wiring mistake rather than anything the peer did wrong at call time.
  final error = RpcStatusException(
    RpcStatus.internal,
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
          if (RpcGrpcCompression.isIdentity(encoding)) {
            throw RpcPeerFaultException(
              RpcStatus.internal,
              'Compressed gRPC payload received without grpc-encoding',
            );
          }
          return RpcGrpcCompression.decompress(
            payload,
            encoding: encoding!,
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

    if (_logger.isInternal) {
      _logger.internal(
        'Created ${_isZeroCopy ? "Zero-copy" : "Serialized"} StreamProcessor for $_methodPath [streamId: $_streamId]${_context?.cancellationToken != null ? " with cancellation token" : ""}',
      );
    }

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

    if (_logger.isInternal) {
      _logger.internal(
        'Stream bound [methodPath: $_methodPath, streamId: $_streamId]',
      );
    }

    final subscription = _scope.listen<RpcTransportMessage>(
      messageStream,
      _handleMessage,
      onError: (Object error, StackTrace stackTrace) {
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
        if (_logger.isInternal) {
          _logger.internal(
            'Stream finished: message_stream_completed [methodPath: $_methodPath, streamId: $_streamId]',
          );
        }
        _endRequests();
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
    _requestController.onListen = subscription.resume;
    _requestController.onPause = subscription.pause;
    _requestController.onResume = subscription.resume;
    if (_requestController.hasListener) {
      // Already subscribed before the bind: onListen will not fire again.
      subscription.resume();
    } else {
      subscription.pause();
    }

    // Initial metadata is not sent on bind; it is sent with the first response
    // or skipped when sending an immediate error.
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
      if (_logger.isInternal) {
        _logger.internal(
          'Response skipped due to cancellation [streamId: $_streamId]',
        );
      }
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
    } else if (_logger.isInternal) {
      // The call was already answered (an error trailer closes the controller)
      // while the handler still produced: a race after the end, not a fault. A
      // warning here let a peer write one per call it made invalid.
      _logger.internal(
        'Response after the call was answered; dropped [streamId: $_streamId]',
      );
    }
  }

  /// Sends an error to the client.
  ///
  /// [fault] false says the status, though a fault code, answers the PEER's
  /// own invalid input (see `RpcStatus.isFaultError`), so it is not an
  /// incident here.
  Future<void> sendError(
    int statusCode,
    String message, {
    Uint8List? statusDetailsBin,
    bool fault = true,
  }) async {
    if (!_isActive) {
      _logger.warning('Attempted to send error on inactive processor');
      return;
    }

    // An application status is an answer, not an incident.
    if (fault && RpcStatus.isFault(statusCode)) {
      _logger.error(
        'Sending error to client: $statusCode - $message [streamId: $_streamId]',
      );
    } else if (_logger.isDebug) {
      _logger.debug(
        'Sending status to client: $statusCode - $message '
        '[streamId: $_streamId]',
      );
    }

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
        if (_logger.isInternal) {
          _logger.internal(
            'Sending Trailers-Only error [streamId: $_streamId]',
          );
        }
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

      if (_logger.isInternal) {
        _logger.internal('Error sent to client [streamId: $_streamId]');
      }
      _trailerSent = true;
    } catch (e, stackTrace) {
      if (_isTransportClosed(e)) {
        if (_logger.isDebug) {
          _logger.debug(
            'Transport closed, skipping error send [streamId: $_streamId]',
          );
        }
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

    if (_logger.isInternal) {
      _logger.internal(
        'Finishing response send for $_methodPath [streamId: $_streamId]',
      );
    }

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

    if (_logger.isInternal) {
      _logger.internal(
        'Closing StreamProcessor for $_methodPath [streamId: $_streamId]',
      );
    }
    _isActive = false;

    await _scope.close();
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

  /// A request could not be sent, so the request stream must not end with a
  /// half-close: the peer would read the requests before it as the whole stream.
  bool _requestSendFailed = false;

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
            if (RpcGrpcCompression.isIdentity(encoding)) {
              throw RpcPeerFaultException(
                RpcStatus.internal,
                'Compressed gRPC payload received without grpc-encoding',
              );
            }
            return RpcGrpcCompression.decompress(
              payload,
              encoding: encoding!,
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

      if (_logger.isInternal) {
        _logger.internal(
          'Created ${_isZeroCopy ? "Zero-copy" : "Serialized"} CallProcessor for $_methodPath [streamId: $_streamId]${_context?.cancellationToken != null ? " with cancellation token" : ""}',
        );
      }

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

  /// Completes when the call is over, however it ended.
  ///
  /// Every ending closes the response controller — END_STREAM, a non-OK
  /// trailer, a deadline, cancellation, the scope's disposal — so this is the
  /// one signal that covers them all. [isActive] does not: it stays true after
  /// a server-ended call, which is why a producer feeding [requestSink] could
  /// not tell that its call had finished.
  ///
  /// Completes only once something has listened to [responses]; a call nobody
  /// reads has nothing to stop for.
  Future<void> get done => _responseController.done;

  /// Stream ID.
  int get streamId => _streamId;

  /// Zero-copy mode flag.
  bool get isZeroCopy => _isZeroCopy;

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

  /// Sends a request to the server.
  Future<void> send(TRequest request) async {
    if (!_isActive) {
      // Returning here reported success for a request that was never sent, and
      // the caller's own `await send(...)` could not tell the difference. On a
      // client-stream the peer then answers over a shorter sequence than the
      // caller handed over, and both sides call it a success.
      _logger.warning('Attempted to send request on inactive processor');
      throw RpcStatusException(
        RpcStatus.unavailable,
        'Request not sent: the call is no longer active',
      );
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

    if (_logger.isInternal) {
      _logger.internal(
        'Finishing request send for $_methodPath [streamId: $_streamId]',
      );
    }

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

  /// Closes the processor and releases resources.
  ///
  /// Delegates to [RpcCallScope.close] which runs all registered
  /// disposers (subscriptions, controllers) in reverse order.
  Future<void> close() async {
    if (!_isActive) return;

    if (_logger.isInternal) {
      _logger.internal(
        'Closing CallProcessor for $_methodPath [streamId: $_streamId]',
      );
    }
    _isActive = false;

    await _scope.close();
  }
}
