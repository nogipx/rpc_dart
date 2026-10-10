// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

part of '_index.dart';

extension _StreamProcessorInternals<
  TRequest extends Object,
  TResponse extends Object
>
    on StreamProcessor<TRequest, TResponse> {
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
      onError: (Object error, StackTrace stackTrace) {
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
          // One record after the send, not one on each side of it.
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
          if (_logger.isDebug) {
            _logger.debug(
              'Transport closed, skipping response send [streamId: $_streamId]',
            );
          }
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
      if (_logger.isInternal) {
        _logger.internal(
          'Trailer sent for $_methodPath [streamId: $_streamId]',
        );
      }
    } catch (e, stackTrace) {
      if (_isTransportClosed(e)) {
        if (_logger.isDebug) {
          _logger.debug(
            'Transport closed, skipping trailer send [streamId: $_streamId]',
          );
        }
        return;
      }
      _logger.error(
        'Failed to send trailer [streamId: $_streamId]',
        error: e,
        stackTrace: stackTrace,
      );
    }
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
      if (_logger.isInternal) {
        _logger.internal(
          'Message skipped due to cancellation [streamId: $_streamId]',
        );
      }
      return;
    }

    if (_logger.isInternal) {
      _logger.internal(
        'Message received [streamId: ${message.streamId}, type: ${message.isMetadataOnly
            ? "metadata"
            : message.isDirect
            ? "zero_copy"
            : "serialized"}, size: ${message.payload?.length}]',
      );
    }

    // Extract encoding hints from initial request metadata.
    if (message.isMetadataOnly && message.metadata != null) {
      final meta = message.metadata!;

      // grpc-encoding: what the peer used to compress its requests.
      final reqEnc = meta.getHeaderValue(RpcHeaders.grpcEncoding);
      if (!RpcGrpcCompression.isIdentity(reqEnc)) {
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
      if (_logger.isInternal) {
        _logger.internal(
          'Stream finished: end_of_stream_received [methodPath: $_methodPath, streamId: $_streamId]',
        );
      }
      _endRequests();
    }
  }

  /// Ends the request side, reporting a frame the peer never finished.
  ///
  /// A half-close with bytes of a frame still buffered is a MALFORMED request,
  /// not an empty one, and the parser's leftovers die with the stream — so unless
  /// it is said here it is never said at all. A server stream carries exactly one
  /// request, so it waits out its deadline; a client stream's handler is told the
  /// peer sent nothing where it in fact sent an incomplete something.
  ///
  /// Both endings route here because the half-close reaches a processor two ways:
  /// as a frame carrying end-of-stream, and as the bound message stream simply
  /// finishing. The rule has to be the same in both or the answer depends on the
  /// shape of the feed.
  void _endRequests() {
    if (_requestController.isClosed) return;
    if (_parser?.holdsPartialFrame ?? false) {
      _requestController.addError(
        RpcStatusException(
          RpcStatus.invalidArgument,
          'Request stream closed mid-message: the last gRPC frame is '
          'incomplete',
        ),
        StackTrace.current,
      );
    }
    _requestController.close();
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

    if (_logger.isInternal) {
      _logger.internal(
        'Message received [streamId: $_streamId, type: serialized_data, '
        'size: ${messageBytes.length}]',
      );
    }

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
          // The PEER's bytes did not decode: its fault, answered INTERNAL as
          // gRPC does, but not an incident here (IRpcPeerFault).
          if (_logger.isInternal) {
            _logger.internal(
              'request_deserialization error [methodPath: $_methodPath, '
              'streamId: $_streamId, size: ${msgBytes.length}]: $e',
            );
          }
          if (!_requestController.isClosed) {
            _requestController.addError(
              RpcPeerFaultException(
                RpcStatus.internal,
                'Request payload could not be decoded',
              ),
              stackTrace,
            );
          }
        }
      }
    } catch (e, stackTrace) {
      if (RpcStatus.isFaultError(e)) {
        _logger.error(
          'message_parsing error [methodPath: $_methodPath, streamId: $_streamId, size: ${messageBytes.length}]',
          error: e,
          stackTrace: stackTrace,
        );
      } else if (_logger.isInternal) {
        _logger.internal(
          'message_parsing refused [methodPath: $_methodPath, '
          'streamId: $_streamId]: $e',
        );
      }
      if (!_requestController.isClosed) {
        _requestController.addError(e, stackTrace);
      }
    }
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
        if (_logger.isInternal) {
          _logger.internal(
            'Operation cancelled, shutting down processor [streamId: $_streamId]',
          );
        }
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
      onError: (Object error, StackTrace stackTrace) {
        _logger.error(
          'Error monitoring cancellation [streamId: $_streamId]',
          error: error,
          stackTrace: stackTrace,
        );
      },
    );
  }
}
