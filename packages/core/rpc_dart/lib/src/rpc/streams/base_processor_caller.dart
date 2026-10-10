// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

part of '_index.dart';

/// What a caller is told when its codec cannot decode a response: INTERNAL, as
/// the server answers the same failure on a request. The codec's own exception
/// type is not part of the API, and a caller catching [RpcException], or an
/// interceptor reading a status, would otherwise miss it. Already logged with
/// the original error where it is caught.
Object _undecodableResponse(Object error) => error is RpcException
    ? error
    : const RpcStatusException(
        RpcStatus.internal,
        'Response could not be decoded',
      );

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
        if (logger.isInternal) {
          logger.internal(
            'Cancellation delivered via stream reset [streamId: $streamId]',
          );
        }
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

    if (logger.isInternal) {
      logger.internal(
        'Sending cancellation notice to server [streamId: $streamId]',
      );
    }
    await transport.sendMetadata(
      streamId,
      cancellationMetadata,
      endStream: true,
    );
    if (logger.isInternal) {
      logger.internal(
        'Cancellation notice sent to server [streamId: $streamId]',
      );
    }
  } catch (e, stackTrace) {
    logger.error(
      'Failed to send cancellation metadata [streamId: $streamId]',
      error: e,
      stackTrace: stackTrace,
    );
  }
}

extension _CallProcessorInternals<
  TRequest extends Object,
  TResponse extends Object
>
    on CallProcessor<TRequest, TResponse> {
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
          if (_requestSendFailed) return;
          await _transport.finishSending(_streamId);
          if (_logger.isInternal) {
            _logger.internal(
              'finishSending completed for $_methodPath [streamId: $_streamId]',
            );
          }
        } catch (e, stackTrace) {
          _logger.error(
            'Failed to finish sending requests [streamId: $_streamId]',
            error: e,
            stackTrace: stackTrace,
          );
        }
      },
      onError: (Object error, StackTrace stackTrace) {
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

        if (_logger.isInternal) {
          _logger.internal(
            'Sending request for $_methodPath [streamId: $_streamId]',
          );
        }

        if (_isZeroCopy) {
          // One record after the send, not one on each side of it.
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
          if (!RpcGrpcCompression.isIdentity(requestEncoding) &&
              !RpcGrpcCompression.isSupported(requestEncoding!)) {
            // UNIMPLEMENTED is what the gRPC spec prescribes for a compression
            // algorithm the receiver does not support, alongside
            // grpc-accept-encoding. Not INTERNAL: the peer can pick another.
            throw RpcStatusException(
              RpcStatus.unimplemented,
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

          if (_logger.isInternal) {
            _logger.internal(
              'Request sent for $_methodPath [streamId: $_streamId]',
            );
          }
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
        // The peer is told the call was abandoned rather than half-closed: a
        // handler reading the requests would otherwise take the ones before
        // this as the complete stream and answer OK.
        _requestSendFailed = true;
        await _sendCancellationToServer('A request could not be sent');
        if (!_requestController.isClosed) {
          unawaited(_requestController.close());
        }
      }
    });
  }

  /// Configures incoming response handling.
  void _setupResponseHandler() {
    final subscription = _scope.listen<RpcTransportMessage>(
      _transport.getMessagesForStream(_streamId),
      _handleResponse,
      onError: (Object error, StackTrace stackTrace) {
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
        if (_logger.isInternal) {
          _logger.internal(
            'Response stream completed for $_methodPath [streamId: $_streamId]',
          );
        }
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
    _responseController.onPause = subscription.pause;
    _responseController.onResume = subscription.resume;
  }

  /// Sends initial metadata with context support.
  Future<void> _sendInitialMetadata() async {
    if (_logger.isInternal) {
      _logger.internal(
        'Sending initial metadata for $_methodPath [streamId: $_streamId]',
      );
    }

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
        RpcHeaders.checkUserHeader(entry.key, entry.value);
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

      if (_logger.isInternal) {
        _logger.internal(
          'Context headers added: ${_context.headers.length} custom + system '
          '[streamId: $_streamId]',
        );
      }
    } else {
      headerMap[RpcHeaders.xRequestId] = RpcContext.empty().requestId;

      if (_logger.isInternal) {
        _logger.internal(
          'Added base request-id for null context [streamId: $_streamId]',
        );
      }
    }

    final metadata = RpcMetadata([
      for (final e in headerMap.entries) RpcHeader(e.key, e.value),
    ], methodPath: baseMetadata.methodPath);
    await _transport.sendMetadata(_streamId, metadata);

    if (_logger.isInternal) {
      _logger.internal(
        'Initial metadata sent for $_methodPath [streamId: $_streamId]',
      );
    }
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

      if (_logger.isInternal) {
        _logger.internal('Deadline exceeded [streamId: $_streamId]');
      }
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
        if (_logger.isInternal) {
          _logger.internal(
            'Operation cancelled by client, notifying server [streamId: $_streamId]',
          );
        }

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
      onError: (Object error, StackTrace stackTrace) {
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

  /// Refuses a call whose context is already cancelled or expired.
  void _checkContextBeforeCall() {
    if (_context == null) return;

    _context.cancellationToken?.throwIfCancelled();

    if (_context.isExpired) {
      throw RpcDeadlineExceededException(_context.deadline!, Duration.zero);
    }

    if (_logger.isInternal) {
      _logger.internal(
        'Context verified: requestId=${_context.requestId}, traceId=${_context.traceId} [streamId: $_streamId]',
      );
    }
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
          if (_logger.isInternal) {
            _logger.internal(
              'Metadata pushed to response stream [streamId: $_streamId]',
            );
          }
        }
      }

      if (message.isDirect && message.directPayload != null) {
        _processDirectResponse(message.directPayload!);
      } else if (!message.isMetadataOnly && message.payload != null) {
        _processResponseData(message.payload!);
      }

      if (message.isEndOfStream) {
        if (_logger.isInternal) {
          _logger.internal(
            'END_STREAM received, closing response stream [streamId: $_streamId]',
          );
        }
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
        if (_logger.isInternal) {
          _logger.internal(
            'Zero-copy response added to response stream [streamId: $_streamId]',
          );
        }
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
        _responseController.addError(_undecodableResponse(e), stackTrace);
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
            if (_logger.isInternal) {
              _logger.internal(
                'Deserialized response added to stream [streamId: $_streamId]',
              );
            }
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
            _responseController.addError(_undecodableResponse(e), stackTrace);
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
}
