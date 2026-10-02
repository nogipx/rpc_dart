// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

part of '../_index.dart';

/// Per-stream state for [UnaryResponder].
/// Consolidates all per-stream flags and encoding values into one object
/// so that cleanup is a single [Map.remove] call.
final class _UnaryStreamState {
  bool requestHandled = false;
  bool initialHeadersSent = false;
  bool belongsToThisMethod = false;
  String? clientAcceptEncoding;
  String? clientRequestEncoding;

  /// Reassembly parser for THIS stream's request frames.
  ///
  /// [RpcMessageParser] carries a buffer between invocations, so it belongs
  /// here with the rest of the per-stream state: one responder can serve
  /// several streams at once (`id == 0` accepts every stream, and this whole
  /// map is keyed by stream id), and a parser shared across them would splice
  /// one stream's leftover bytes onto the front of another stream's frame.
  /// Created lazily — a stream that only ever carries zero-copy payloads or
  /// metadata never needs one.
  RpcMessageParser? parser;
}

/// Unary responder with Stream ID support: handles one request, sends one response.
final class UnaryResponder<TRequest, TResponse> implements IRpcResponder {
  /// Whether this responder subscribes to the whole connection itself.
  ///
  /// **False when the pipeline builds it, which is every server call.** The
  /// subscription is the connection-wide broadcast, so one listener exists per
  /// LIVE UNARY HANDLER and each one is invoked for every inbound frame only to
  /// discard what is not its own — O(N) per frame in the number of concurrent
  /// calls. A pipeline responder is handed its request directly four lines
  /// after construction, so the subscription delivered nothing anyway.
  ///
  /// What it did deliver was `onError`: a transport error that does NOT close
  /// the stream was answered here and nowhere else, because the pipeline's own
  /// `onError` only logged. That duty moved UP rather than away —
  /// `_answerActiveStreams` now does it once for every stream instead of N
  /// times for one each.
  ///
  /// True keeps the old behaviour for a responder constructed directly, which
  /// has no pipeline to feed it.
  final bool listensToTransport;

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
  late final LogScope _logger;

  /// RPC context with cancellation/metadata.
  final RpcContext? _context;

  /// Cancellation subscription.
  StreamSubscription<void>? _cancellationSubscription;

  /// Incoming messages subscription.
  StreamSubscription<void>? _subscription;

  /// Request handler.
  late final FutureOr<TResponse> Function(TRequest request) _handler;

  /// Per-stream state. Single map — one [remove] call cleans up everything.
  final Map<int, _UnaryStreamState> _streamStates = <int, _UnaryStreamState>{};

  _UnaryStreamState _stateFor(int streamId) =>
      _streamStates.putIfAbsent(streamId, _UnaryStreamState.new);

  /// Returns [state]'s parser, creating it on first use.
  ///
  /// The decompressor closes over [state], so it always reads the
  /// `grpc-encoding` its own client advertised (falling back to the server
  /// context) instead of whatever stream happened to be parsed last.
  RpcMessageParser _parserFor(_UnaryStreamState state) =>
      state.parser ??= _policyBoundParser(
        transport: _transport,
        logger: _logger,
        decompressor: (payload, {int? maxOutputBytes}) {
          final encoding =
              state.clientRequestEncoding ??
              _context?.getHeader(RpcHeaders.grpcEncoding);
          if (RpcGrpcCompression.isIdentity(encoding)) {
            // INTERNAL: the peer set the compressed bit and named no encoding,
            // which is a protocol violation no retry can fix.
            throw RpcStatusException(
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
    LogScope? logger,
    this.listensToTransport = true,
  }) : _transport = transport,
       _serviceName = serviceName,
       _methodName = methodName,
       _requestSerializer = requestCodec,
       _responseSerializer = responseCodec,
       _context = context {
    _handler = handler;
    _logger = logger?.child('UnaryResponder') ?? LogScope.noop;
    _methodPath = '/$_serviceName/$_methodName';
    if (_logger.isInternal) {
      _logger.internal(
        'Created unary server for $_methodPath'
        '${_context?.cancellationToken != null ? " with cancellation token" : ""}',
      );
    }

    // Register initial stream as belonging to this method.
    _stateFor(id).belongsToThisMethod = true;

    _setupCancellationMonitoring();
    _setupRequestHandler();
  }

  /// Sets up cancellation monitoring.
  void _setupCancellationMonitoring() {
    if (_context?.cancellationToken != null) {
      _cancellationSubscription = _context!.cancellationToken!.cancelled
          .asStream()
          .listen(
            (_) {
              if (_logger.isInternal) {
                _logger.internal(
                  'Operation cancelled, stopping request handling [id: $id]',
                );
              }

              // Cancel subscription to incoming messages.
              _subscription?.cancel();
            },
            onError: (Object error, StackTrace stackTrace) {
              _logger.error(
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

  /// Whether the call ended while the handler was running.
  ///
  /// Checked AFTER `await _handler(...)`, which is the only part of a unary
  /// call that takes time and so the only window in which a cancel, a deadline,
  /// a `drain()` or an `endpoint.close()` can land. Without it this responder
  /// answered anyway: a DATA frame and `grpc-status: 0` went out on a stream
  /// the caller had already given up on, and a drain that exists to stop
  /// exactly that reported success.
  ///
  /// One token covers all four — the deadline path and `drain()` both cancel it
  /// (`responder_pipeline._onDeadlineExceeded`), and so does
  /// `closeResponderResources`.
  ///
  /// This is what [StreamProcessor] gets from `_isActive`, which gates its
  /// `send`, `sendError` and `finishSending`. The same handler registered as
  /// any streaming shape, or served by the zero-copy unary branch on
  /// [CallProcessor], was already suppressed here; only the codec unary path
  /// was not.
  bool get _callIsOver => _context?.cancellationToken?.isCancelled ?? false;

  /// Whether the pipeline has torn this responder down.
  ///
  /// A closed responder writes NOTHING, not even the CANCELLED notice
  /// [_dropLateResponse] exists for: the stream is no longer this call's to write
  /// on. Over a reconnecting transport the peer restarts its numbering on each
  /// socket, so a late trailer on the old id reaches whichever call now holds
  /// that number — and the new caller is answered CANCELLED for a call it never
  /// cancelled.
  ///
  /// The other shapes have this already: [StreamProcessor.close] clears
  /// `_isActive`, which gates every write it makes.
  bool _closed = false;

  /// Set when a second request reaches this responder while the handler runs
  /// on the first; the answer is then INTERNAL in place of the response (see
  /// [tooManyMessages]). The pipeline refuses one it routes itself at once.
  bool _tooManyRequests = false;

  /// Drops a finished handler's answer and tells the caller the call ended.
  ///
  /// A status, not silence. Dropping the response and returning left the caller
  /// with nothing at all — it waited out its own deadline for a call the server
  /// had already finished with, which is worse than the wrong answer this
  /// replaces. Same principle as the undelivered-response audit: a response
  /// that did not reach the peer must not read as success, and must not vanish.
  ///
  /// Best-effort by construction. The reason the call ended is often that the
  /// transport went away, so this send is expected to fail and its failure is
  /// not news.
  Future<void> _dropLateResponse(int streamId) async {
    final reason = _context?.cancellationToken?.reason ?? 'call ended';
    if (_logger.isInternal) {
      _logger.internal(
        'Handler finished after the call ended; answering CANCELLED instead '
        '[streamId: $streamId, reason: $reason]',
      );
    }
    try {
      await _transport.sendMetadata(
        streamId,
        RpcMetadata.forTrailer(RpcStatus.cancelled, message: reason),
        endStream: true,
      );
    } catch (_) {
      // Nothing to report to: see above.
    }
  }

  void _setupRequestHandler() {
    if (!listensToTransport) {
      if (_logger.isInternal) {
        _logger.internal('Fed directly; not listening for $_methodPath');
      }
      return;
    }

    if (_logger.isInternal) {
      _logger.internal('Configuring request handler for $_methodPath');
    }

    _subscription = _transport.incomingMessages.listen(
      // An `async` listen callback nobody awaits: a throw reaches the zone, and
      // a server with no zone handler exits on that. Reachable through
      // handleMessage, whose own error path answers the peer over a transport
      // that may already be gone.
      // SYNCHRONOUS, and the filter is the first thing it does. This is a
      // connection-wide broadcast and every live unary handler holds its own
      // listener on it, so an `async` body allocates a Future and a microtask
      // per frame per handler — even for a frame it immediately discards,
      // because an `async` function returns a Future whatever it does. With 200
      // parked handlers, 3000 upstream frames became 600 000 such allocations:
      // 48 ms at one handler against 333 at two hundred.
      (message) {
        if (id != 0 && message.streamId != id) return;
        unawaited(_guardedIncoming(message));
      },
      onError: (Object error, StackTrace stackTrace) async {
        _logger.error(
          'Transport error for $_methodPath',
          error: error,
          stackTrace: stackTrace,
        );

        // Unless the channel said this is an OBSERVATION, not a failure. An
        // advisory error — a proxy's app-level keepalive arriving as a text
        // frame — reports one discarded frame over a connection that still
        // works, and answering it fails every call in flight for nothing.
        // `RpcChannelTransport` already withholds these from its per-stream
        // controllers for exactly this reason; this listener is on the
        // connection-wide broadcast, where they still arrive.
        if (error is IRpcAdvisoryChannelError) return;

        // ANSWER it. Logging alone leaves the caller waiting for a response
        // that will never come: it eventually reports UNAVAILABLE "Stream
        // closed without receiving response", which says nothing about the
        // cause. The three streaming shapes route this through
        // StreamProcessor's request controller and the zero-copy unary branch
        // calls sendError directly; this one did neither.
        final wire = wireStatusFor(error);
        for (final entry in _streamStates.entries.toList()) {
          final state = entry.value;
          if (!state.belongsToThisMethod || state.requestHandled) continue;
          state.requestHandled = true;
          try {
            await _transport.sendMetadata(
              entry.key,
              RpcMetadata.forTrailer(
                wire.status,
                message: wire.message,
                statusDetailsBin: wire.detailsBin,
                maxMessageLength: _policyOf(_transport).maxHeaderValueBytes,
              ),
              endStream: true,
            );
          } catch (e, st) {
            _logger.error(
              'Failed to report the transport error to the peer '
              '[streamId: ${entry.key}]',
              error: e,
              stackTrace: st,
            );
          }
        }
      },
    );
  }

  /// The listener's async half. Nothing may escape it: a throw from a listen
  /// callback reaches the zone, and a server with no zone handler exits on it.
  Future<void> _guardedIncoming(RpcTransportMessage message) async {
    try {
      await _onIncomingMessage(message);
    } catch (e, stackTrace) {
      _logger.error(
        'Failed to process incoming message for $_methodPath '
        '[streamId: ${message.streamId}]',
        error: e,
        stackTrace: stackTrace,
      );
    }
  }

  /// Routes one inbound transport message; the listener above owns the guard.
  Future<void> _onIncomingMessage(RpcTransportMessage message) async {
    final streamId = message.streamId;

    // If responder id is 0 (default), accept any messages (useful for tests).
    if (id != 0 && streamId != id) {
      return;
    }

    // For metadata, ensure it targets this method.
    if (message.isMetadataOnly && message.metadata != null) {
      final state = _stateFor(streamId);
      if (message.methodPath == _methodPath) {
        state.belongsToThisMethod = true;
        if (_logger.isInternal) {
          _logger.internal(
            'Unary server: stream $streamId bound to method $_methodPath',
          );
        }
      }
      // Capture client's grpc-accept-encoding for response compression.
      final accept = message.metadata!.getHeaderValue(
        RpcHeaders.grpcAcceptEncoding,
      );
      if (accept != null) {
        state.clientAcceptEncoding = accept;
      }
      // Capture client's grpc-encoding to decompress incoming requests.
      final requestEnc = message.metadata!.getHeaderValue(
        RpcHeaders.grpcEncoding,
      );
      if (!RpcGrpcCompression.isIdentity(requestEnc)) {
        state.clientRequestEncoding = requestEnc;
      }
      return; // Register metadata only.
    }

    // For data messages, ensure they belong to this method.
    if (_streamStates[streamId]?.belongsToThisMethod != true) {
      return; // Not for this responder.
    }

    if (_streamStates[streamId]?.requestHandled == true) {
      if (message.payload != null || message.isDirect) {
        _tooManyRequests = true;
      }
      if (_logger.isInternal) {
        _logger.internal(
          'Ignoring extra message for stream $streamId (request already handled)',
        );
      }
      return;
    }

    // Check cancellation before processing.
    try {
      _checkCancellation();
    } catch (e) {
      if (_logger.isInternal) {
        _logger.internal(
          'Message skipped due to cancellation [streamId: $streamId]',
        );
      }
      return;
    }

    var incomplete = false;
    if (message.isDirect && message.directPayload != null) {
      // Zero-copy: handle object directly.
      await handleDirectMessage(message);
    } else if (!message.isMetadataOnly && message.payload != null) {
      incomplete = await handleMessage(message);
    }

    // If the client closed the stream without sending data.
    final eosState = _streamStates[streamId];
    if (message.isEndOfStream &&
        eosState?.belongsToThisMethod == true &&
        eosState?.requestHandled != true) {
      // Data DID arrive, just not all of a frame. Saying "closed without data"
      // sends the peer looking for a request it made.
      if (incomplete) {
        await answerIncompleteRequest(streamId);
        return;
      }
      eosState!.requestHandled = true;
      _logger.warning(
        'Client closed stream without sending data [streamId: $streamId]',
      );

      // Send an error trailer.
      await _transport.sendMetadata(
        streamId,
        RpcMetadata.forTrailer(
          RpcStatus.invalidArgument,
          message: 'Request not received: stream closed without data',
          maxMessageLength: _policyOf(_transport).maxHeaderValueBytes,
        ),
        endStream: true,
      );

      // Clear state for this stream.
      _streamStates.remove(streamId);
    }
  }

  /// Handles a payload message (can be called for pre-received messages).
  ///
  /// Returns true when the request is STILL INCOMPLETE: the payload held part of
  /// a gRPC frame and the rest has not arrived. The caller owns what happens
  /// next — route further data frames here, and answer the peer if it half-closes
  /// instead. Everything else returns false, including every failure, because a
  /// failure has already been answered.
  ///
  /// **The answer is returned rather than left on the state** that the `finally`
  /// below removes. Reading it afterwards is what round 547 got wrong: a
  /// COMPLETED call reported "still arriving" and its teardown was skipped,
  /// surfacing two layers away as an undisposed call scope.
  Future<bool> handleMessage(RpcTransportMessage message) async {
    final streamId = message.streamId;
    // Set only on the incomplete path, and the `finally` reads it to decide
    // whether this stream's state -- which OWNS the reassembly parser -- may be
    // dropped. A local, so it cannot be observed after the fact.
    var incomplete = false;

    // Check cancellation before processing.
    try {
      _checkCancellation();
    } catch (e) {
      if (_logger.isInternal) {
        _logger.internal('Message processing cancelled [streamId: $streamId]');
      }
      return false;
    }

    // Ensure the message targets this responder (id=0 accepts all for tests).
    if (id != 0 && streamId != id) {
      if (_logger.isInternal) {
        _logger.internal(
          'Message for stream $streamId does not belong to this responder (id=$id), skipping',
        );
      }
      return false;
    }

    final state = _stateFor(streamId);

    if (state.requestHandled) {
      if (_logger.isInternal) {
        _logger.internal(
          'Message for stream $streamId already handled, skipping',
        );
      }
      return false;
    }

    if (message.isMetadataOnly || message.payload == null) {
      _logger.internal('Received message without payload, skipping');
      return false;
    }

    // Mark as handling immediately to prevent duplicates.
    state.requestHandled = true;
    if (_logger.isInternal) {
      _logger.internal(
        'Handling request for $_methodPath [streamId: $streamId]',
      );
    }

    try {
      // Determine response encoding from client's grpc-accept-encoding.
      final responseEncoding = _selectResponseEncoding(streamId);

      // Send initial headers if not already sent.
      if (!state.initialHeadersSent) {
        if (_logger.isInternal) {
          _logger.internal('Sending initial headers [streamId: $streamId]');
        }
        await _transport.sendMetadata(
          streamId,
          RpcMetadata.forServerInitialResponse(encoding: responseEncoding),
        );
        state.initialHeadersSent = true;
      }

      // Deserialize request using parser to extract framed messages.
      if (_logger.isInternal) {
        _logger.internal(
          'Parsing request frame of ${message.payload!.length} bytes '
          '[streamId: $streamId]',
        );
      }
      final parser = _parserFor(state);
      final messages = parser(message.payload!);
      if (messages.isEmpty) {
        // The parser is holding the beginning of a frame, so more input would
        // complete it. Wait, and let the caller route the rest here: the only
        // transports that split a frame are third-party ones forwarding raw
        // chunks, and before this they got INTERNAL on unary alone while both
        // streaming shapes answered.
        //
        // `holdsPartialFrame`, not `messages.isEmpty`: a REFUSED frame also
        // yields nothing, and waiting for a frame the policy already rejected
        // would report a truncated request where `maxMessageLengthBytes` fired.
        if (parser.holdsPartialFrame) {
          incomplete = true;
          // Not handled after all: the next fragment must be let through, and
          // the state (which owns the parser and its buffer) must survive.
          state.requestHandled = false;
          if (_logger.isInternal) {
            _logger.internal(
              'Request frame incomplete, awaiting the rest [streamId: $streamId]',
            );
          }
          return true;
        }
        _logger.error(
          'Failed to extract message from payload [streamId: $streamId]',
        );
        throw RpcStatusException(
          RpcStatus.internal,
          'Failed to extract message from payload',
        );
      }

      if (messages.length > 1) throw tooManyMessages('request');
      final request = _requestSerializer.deserialize(messages.first);

      // Handle request.
      final response = await _handler(request);

      // See [_callIsOver]: the handler is the only slow part of a unary call,
      // so this is where a cancel, deadline, drain or close lands.
      if (_closed) return false;
      if (_callIsOver) {
        await _dropLateResponse(streamId);
        return false;
      }
      if (_tooManyRequests) throw tooManyMessages('request');

      // Serialize and optionally compress response.
      final serializedResponse = _responseSerializer.serialize(response);
      final (payload, useCompression) = RpcGrpcCompression.compressIfSmaller(
        serializedResponse,
        encoding: responseEncoding,
      );
      final framedResponse = RpcMessageFrame.encode(
        payload,
        compressed: useCompression,
      );
      await _transport.sendMessage(streamId, framedResponse);

      // Send success trailer.
      await _transport.sendMetadata(
        streamId,
        RpcMetadata.forTrailer(RpcStatus.ok),
        endStream: true,
      );

      // ONE record for one served call, written where every fact exists.
      //
      // This method narrated itself in EIGHT records -- deserializing,
      // handling, handled, serializing, serialized, sending, sending trailer,
      // sent -- around six lines that cannot fail between them. What survives
      // is what the code does not already say: the payload size, and whether
      // it went out compressed.
      if (_logger.isInternal) {
        _logger.internal(
          'Served $_methodPath [streamId: $streamId] '
          '${serializedResponse.length}B'
          '${useCompression ? ' compressed as $responseEncoding' : ''}',
        );
      }
    } catch (e, stackTrace) {
      // A handler that THROWS a status is answering, not failing: NOT_FOUND is
      // the documented way to say "no such record". Only a genuine fault, or a
      // throw carrying no status at all, is an incident worth an error record.
      final code = e is RpcStatusException ? e.statusCode : null;
      if (code == null || RpcStatus.isFault(code)) {
        _logger.error(
          'Request processing failed [streamId: $streamId]',
          error: e,
          stackTrace: stackTrace,
        );
      } else if (_logger.isDebug) {
        _logger.debug('Handler answered $code: $e [streamId: $streamId]');
      }

      // Send initial headers if not already sent.
      if (!state.initialHeadersSent) {
        await _transport.sendMetadata(
          streamId,
          RpcMetadata.forServerInitialResponse(),
        );
        state.initialHeadersSent = true;
      }

      // On error, send trailer with status.
      // RpcStatusException carries a specific gRPC status code; all other
      // exceptions map to INTERNAL.
      if (_logger.isInternal) {
        _logger.internal('Sending error trailer [streamId: $streamId]');
      }
      final wire = wireStatusFor(e);
      await _transport.sendMetadata(
        streamId,
        RpcMetadata.forTrailer(
          wire.status,
          message: wire.message,
          statusDetailsBin: wire.detailsBin,
          // The STATUS must survive a message longer than the header cap; see
          // RpcMetadata.forTrailer. Without this the trailer failed validation,
          // the throw escaped into _detachedDispatch, and a handler's chosen
          // status became a generic INTERNAL "Responder dispatch failed".
          maxMessageLength: _policyOf(_transport).maxHeaderValueBytes,
        ),
        endStream: true,
      );
    } finally {
      // Clear state for this stream (single call removes all per-stream data).
      //
      // NOT while a frame is incomplete: this state owns the reassembly parser,
      // so dropping it here throws away the bytes already received and the next
      // fragment starts a new frame in the middle of the old one.
      if (!incomplete) {
        if (_logger.isInternal) {
          _logger.internal('Clearing state for stream $streamId');
        }
        _streamStates.remove(streamId);
      }
    }
    return false;
  }

  /// Whether [streamId] is waiting for the rest of a gRPC frame RIGHT NOW.
  ///
  /// Asked of the parser, which is the only thing that knows. A caller cannot
  /// use its own "incomplete" bookkeeping for this: that stays true while a later
  /// fragment is being processed, and the request is no longer waiting then — it
  /// is running. Answering the peer on that reading closes the responder out from
  /// under its own handler, which is silent, because a closed responder writes
  /// nothing.
  bool isAwaitingRequest(int streamId) {
    final state = _streamStates[streamId];
    if (state == null || state.requestHandled) return false;
    return state.parser?.holdsPartialFrame ?? false;
  }

  /// Answers a peer that half-closed while a frame was still incomplete.
  ///
  /// INVALID_ARGUMENT names the malformed request. Merely waiting is the failure
  /// this whole mechanism can introduce — round 518's partial version turned an
  /// immediate error into a hang, which is worse — so the caller must reach this
  /// on every path where the request can stop short.
  Future<void> answerIncompleteRequest(int streamId) async {
    final state = _streamStates[streamId];
    if (state == null || state.requestHandled) return;
    state.requestHandled = true;
    _logger.warning(
      'Client half-closed mid-frame [streamId: $streamId]; the last gRPC frame '
      'is incomplete',
    );
    try {
      if (!state.initialHeadersSent) {
        await _transport.sendMetadata(
          streamId,
          RpcMetadata.forServerInitialResponse(),
        );
        state.initialHeadersSent = true;
      }
      await _transport.sendMetadata(
        streamId,
        RpcMetadata.forTrailer(
          RpcStatus.invalidArgument,
          message:
              'Request stream closed mid-message: the last gRPC frame is '
              'incomplete',
          maxMessageLength: _policyOf(_transport).maxHeaderValueBytes,
        ),
        endStream: true,
      );
    } finally {
      _streamStates.remove(streamId);
    }
  }

  /// Zero-copy payload handling.
  Future<void> handleDirectMessage(RpcTransportMessage message) async {
    final streamId = message.streamId;

    // Check cancellation before processing.
    try {
      _checkCancellation();
    } catch (e) {
      if (_logger.isInternal) {
        _logger.internal(
          'Zero-copy message processing cancelled [streamId: $streamId]',
        );
      }
      return;
    }

    // Ensure message targets this responder.
    if (id != 0 && streamId != id) {
      if (_logger.isInternal) {
        _logger.internal(
          'Zero-copy message for stream $streamId does not belong to this responder (id=$id), skipping',
        );
      }
      return;
    }

    final state = _stateFor(streamId);

    if (state.requestHandled) {
      if (_logger.isInternal) {
        _logger.internal(
          'Zero-copy message for stream $streamId already handled, skipping',
        );
      }
      return;
    }

    // Mark as handling immediately.
    state.requestHandled = true;
    if (_logger.isInternal) {
      _logger.internal(
        'Zero-copy request processing for $_methodPath [streamId: $streamId]',
      );
    }

    try {
      // Send initial headers if not already sent.
      if (!state.initialHeadersSent) {
        if (_logger.isInternal) {
          _logger.internal('Sending initial headers [streamId: $streamId]');
        }
        // Zero-copy bypasses serialization/compression; no encoding header needed.
        await _transport.sendMetadata(
          streamId,
          RpcMetadata.forServerInitialResponse(),
        );
        state.initialHeadersSent = true;
      }

      // Zero-copy: get object directly without deserialization.
      final request = message.directPayload as TRequest;

      // Handle request.
      final response = await _handler(request);

      // See [_callIsOver]. Same window as the codec branch.
      if (_closed) return;
      if (_callIsOver) {
        await _dropLateResponse(streamId);
        return;
      }
      if (_tooManyRequests) throw tooManyMessages('request');

      // Zero-copy: send response directly if supported.
      final direct = _transport.supportsZeroCopy;
      if (direct) {
        await _transport.sendDirectObject(streamId, response as Object);
      } else {
        // Fallback to standard serialization for other transports.
        final serializedResponse = _responseSerializer.serialize(response);
        final framedResponse = RpcMessageFrame.encode(serializedResponse);
        await _transport.sendMessage(streamId, framedResponse);
      }

      // Send success trailer.
      await _transport.sendMetadata(
        streamId,
        RpcMetadata.forTrailer(RpcStatus.ok),
        endStream: true,
      );

      // ONE record, and the branch it names is the only thing here the code
      // does not make obvious: whether the transport took the object directly
      // or fell back to serializing it. Seven records said the rest.
      if (_logger.isInternal) {
        _logger.internal(
          'Served $_methodPath zero-copy [streamId: $streamId] '
          '${direct ? 'sent directly' : 'fell back to serialization'}',
        );
      }
    } catch (e, stackTrace) {
      _logger.error(
        'Zero-copy request processing error [streamId: $streamId]',
        error: e,
        stackTrace: stackTrace,
      );

      // Send initial headers if not already sent.
      if (!state.initialHeadersSent) {
        await _transport.sendMetadata(
          streamId,
          RpcMetadata.forServerInitialResponse(),
        );
        state.initialHeadersSent = true;
      }

      // On error, send error trailer.
      final wire2 = wireStatusFor(e);
      await _transport.sendMetadata(
        streamId,
        RpcMetadata.forTrailer(
          wire2.status,
          message: wire2.message,
          statusDetailsBin: wire2.detailsBin,
          maxMessageLength: _policyOf(_transport).maxHeaderValueBytes,
        ),
        endStream: true,
      );
    } finally {
      // Clear state for this stream (single call removes all per-stream data).
      if (_logger.isInternal) {
        _logger.internal('Zero-copy cleanup for stream $streamId');
      }
      _streamStates.remove(streamId);
    }
  }

  /// Picks the best response encoding the client advertised it can decompress.
  ///
  /// Checks incoming request metadata first, then falls back to server context.
  /// Returns `null` if no compression should be applied (identity or unknown).
  String? _selectResponseEncoding(int streamId) {
    final accept =
        _streamStates[streamId]?.clientAcceptEncoding ??
        _context?.getHeader(RpcHeaders.grpcAcceptEncoding);
    return RpcGrpcCompression.selectResponseEncoding(accept);
  }

  /// Closes the responder; transport remains open.
  @override
  Future<void> close() async {
    _closed = true;
    await _subscription?.cancel();
    await _cancellationSubscription?.cancel();
    if (_logger.isInternal) {
      _logger.internal('Closed unary server $_methodPath');
    }
  }
}
