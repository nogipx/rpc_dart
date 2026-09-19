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
          if (encoding == null || encoding == RpcGrpcCompression.identity) {
            // INTERNAL: the peer set the compressed bit and named no encoding,
            // which is a protocol violation no retry can fix.
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

  void _setupRequestHandler() {
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
      if (requestEnc != null && requestEnc != RpcGrpcCompression.identity) {
        state.clientRequestEncoding = requestEnc;
      }
      return; // Register metadata only.
    }

    // For data messages, ensure they belong to this method.
    if (_streamStates[streamId]?.belongsToThisMethod != true) {
      return; // Not for this responder.
    }

    if (_streamStates[streamId]?.requestHandled == true) {
      // Ignore additional messages after first request handled.
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

    if (message.isDirect && message.directPayload != null) {
      // Zero-copy: handle object directly.
      await handleDirectMessage(message);
    } else if (!message.isMetadataOnly && message.payload != null) {
      await handleMessage(message);
    }

    // If the client closed the stream without sending data.
    final eosState = _streamStates[streamId];
    if (message.isEndOfStream &&
        eosState?.belongsToThisMethod == true &&
        eosState?.requestHandled != true) {
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
  Future<void> handleMessage(RpcTransportMessage message) async {
    final streamId = message.streamId;

    // Check cancellation before processing.
    try {
      _checkCancellation();
    } catch (e) {
      if (_logger.isInternal) {
        _logger.internal('Message processing cancelled [streamId: $streamId]');
      }
      return;
    }

    // Ensure the message targets this responder (id=0 accepts all for tests).
    if (id != 0 && streamId != id) {
      if (_logger.isInternal) {
        _logger.internal(
          'Message for stream $streamId does not belong to this responder (id=$id), skipping',
        );
      }
      return;
    }

    final state = _stateFor(streamId);

    if (state.requestHandled) {
      if (_logger.isInternal) {
        _logger.internal(
          'Message for stream $streamId already handled, skipping',
        );
      }
      return;
    }

    if (message.isMetadataOnly || message.payload == null) {
      _logger.internal('Received message without payload, skipping');
      return;
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
      final messages = _parserFor(state)(message.payload!);
      if (messages.isEmpty) {
        _logger.error(
          'Failed to extract message from payload [streamId: $streamId]',
        );
        throw RpcStatusException(
          RpcStatus.internal,
          'Failed to extract message from payload',
        );
      }

      final request = _requestSerializer.deserialize(messages.first);

      // Handle request.
      final response = await _handler(request);

      // Serialize and optionally compress response.
      final serializedResponse = _responseSerializer.serialize(response);
      final useCompression = responseEncoding != null;
      final payload = useCompression
          ? RpcGrpcCompression.compress(
              serializedResponse,
              encoding: responseEncoding,
            )
          : serializedResponse;
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
      _logger.error(
        'Request processing failed [streamId: $streamId]',
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
      if (_logger.isInternal) {
        _logger.internal('Clearing state for stream $streamId');
      }
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
    await _subscription?.cancel();
    await _cancellationSubscription?.cancel();
    if (_logger.isInternal) {
      _logger.internal('Closed unary server $_methodPath');
    }
  }
}
