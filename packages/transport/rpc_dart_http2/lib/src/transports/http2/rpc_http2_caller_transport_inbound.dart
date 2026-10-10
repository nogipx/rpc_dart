// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

part of 'rpc_http2_caller_transport.dart';

/// How many policy violations a connection may cost before the peer is
/// treated as hostile. The same 256 as `RpcChannelTransport`.
const int _maxPolicyViolations = 256;

extension _Http2CallerInbound on RpcHttp2CallerTransport {
  /// Subscribes to one stream's incoming messages.
  void _setupStreamListener(
    int streamId,
    http2.ClientTransportStream stream,
    String methodPath,
  ) {
    final subscription = stream.incomingMessages.listen(
      (http2.StreamMessage message) {
        _handleIncomingMessage(streamId, message, methodPath);
      },
      onError: (Object error, StackTrace stackTrace) {
        _logger?.error(
          'Error on stream $streamId',
          error: error,
          stackTrace: stackTrace,
        );

        // A peer RESET is a gRPC status, not a package:http2 exception.
        //
        // RST_STREAM is how a real gRPC server aborts one call while the
        // connection stays healthy: a server-side deadline, a server at
        // capacity refusing the stream, a proxy dropping it. Measured against
        // a raw package:http2 server that reset the stream, every shape came
        // back as `StreamTransportException: HTTP/2 error: Stream error:
        // Stream was terminated by peer (errorCode: 8)` -- before any
        // response, after headers, and mid server-stream alike.
        //
        // Nothing above the transport can act on that: RpcRetryInterceptor,
        // circuit breakers and failover all key off the gRPC status, so a
        // REFUSED_STREAM from an overloaded server -- which is safe to retry,
        // because the server never processed the request -- was as
        // unclassifiable as a deliberate CANCEL. Same defect as the raw
        // StateError on a drained connection (ff1f6337) and as non-200
        // statuses collapsing to INTERNAL (e4756025).
        //
        // The code is mapped through the spec table rather than flattened to
        // one status on purpose: CANCEL must NOT be retried and
        // REFUSED_STREAM must be, so a blanket answer is wrong in one
        // direction or the other.
        if (error is http2.StreamTransportException) {
          final code = http2ErrorCodeFromMessage(error.message);
          final status = code == null
              ? RpcStatus.internal
              : grpcStatusFromHttp2ErrorCode(code);
          _emitStreamError(
            streamId,
            RpcStatusException(
              status,
              'HTTP/2 stream $streamId was reset by the peer'
              '${code == null ? '' : ' (errorCode: $code)'}',
            ),
            stackTrace: stackTrace,
          );
          return;
        }

        // A CONNECTION-level failure is UNAVAILABLE, and must be a status for
        // the same reason the stream reset above must: nothing over the
        // transport can classify a raw package:http2 exception, so retry,
        // circuit breakers and failover all sit it out.
        //
        // This is the connection-death sibling of the RST_STREAM mapping, and
        // keepalive makes it ordinary rather than exotic: a half-open path is
        // now deliberately torn down, and every call in flight on it lands
        // here. Measured through a frozen relay with pingInterval 2s, before
        // this mapping:
        //
        //   call over dead path = TransportConnectionException after 3962ms
        //
        // i.e. exactly the unclassifiable shape ff1f6337 (GOAWAY -> StateError)
        // and 1cce29fa (RST_STREAM -> StreamTransportException) each fixed on
        // their own path.
        //
        // UNAVAILABLE, not INTERNAL: the connection died, so the call may well
        // succeed on a fresh one -- which is precisely what makes it retryable,
        // and matches what a new call on an already-dead connection reports.
        if (error is http2.TransportConnectionException) {
          _emitStreamError(
            streamId,
            RpcStatusException(
              RpcStatus.unavailable,
              'HTTP/2 connection to $_host:$_port failed while stream '
              '$streamId was in flight (errorCode: ${error.errorCode}); '
              'reconnect and retry',
            ),
            stackTrace: stackTrace,
            connectionWide: true,
          );
          return;
        }

        _emitStreamError(
          streamId,
          error,
          stackTrace: stackTrace,
          connectionWide: true,
        );
      },
      onDone: () {
        if (_logger?.isInternal ?? false) {
          _logger?.internal('Stream $streamId ended');
        }

        if (_statusReceived.contains(streamId)) {
          _emit(RpcTransportMessage(streamId: streamId, isEndOfStream: true));
        } else {
          // No trailers and no Trailers-Only status: the response was cut off.
          // Reporting a clean end here would hand the consumer partial data as
          // if it were complete -- a server stream truncated by a dead peer
          // looking exactly like one that finished.
          // A status-less end means TWO different things and only one of them may
          // be retried, so the status is chosen rather than fixed.
          //
          // The connection going away is the retryable one: nothing completed, and
          // a fresh connection may well succeed -- which is what `server.stop()`
          // mid-call looks like from here, and the behaviour
          // `graceful_drain_on_stop_test` requires by name.
          //
          // A HEALTHY connection ending a stream cleanly with no trailers is the
          // other one: the request reached a peer that answered and then forgot its
          // status, so the work may already have run. Measured with
          // `maxAttempts: 3`, that shape made the server execute one unary call
          // THREE times, because UNAVAILABLE is exactly what `RpcRetryInterceptor`
          // retries by design. grpc-go draws the same line.
          // `_isClosed` belongs here too: when THIS side is tearing down, the peer
          // did not forget anything -- we hung up. Without it one close() produced
          // a mixed answer for one event, `status 14` for the first stream and
          // `status 13` for the rest, depending on where `isOpen` had got to.
          final dying =
              _isClosed || _drainSignal.goawayReceived || !_connection.isOpen;
          final status = dying ? RpcStatus.unavailable : RpcStatus.internal;
          _logger?.warning(
            'Stream $streamId ended without a gRPC status; reporting $status '
            'rather than a clean end',
          );
          _emit(
            RpcTransportMessage(
              streamId: streamId,
              metadata: RpcMetadata([
                RpcHeader(RpcHeaders.grpcStatus, status.toString()),
                RpcHeader(
                  RpcHeaders.grpcMessage,
                  RpcMetadata.encodeGrpcMessage(
                    dying
                        ? 'Response ended without a gRPC status (connection lost '
                              'or stream reset before trailers)'
                        : 'Response ended without a gRPC status (the peer closed '
                              'the stream before sending trailers)',
                  ),
                ),
              ]),
              isEndOfStream: true,
              methodPath: methodPath,
            ),
          );
        }

        // OUR half may still be open: the server answered and ended first, so
        // nothing else will ever close it -- `releaseStreamId`'s RST branch needs
        // the entry this line removes, and `finishSending` returns early without
        // it. Measured against a server answering before the client half-closed:
        // 3 of 3 streams left half-open at the peer, each holding a
        // MAX_CONCURRENT_STREAMS slot, with every map on this side reading 0.
        //
        // RST_STREAM, not an empty END_STREAM, for the reason `releaseStreamId`
        // gives: a stream we have NOT half-closed is one the request side never
        // finished, and RST is the legal way to drop it.
        final ending = _activeStreams.remove(streamId);
        if (ending != null && !_halfClosedLocal.contains(streamId)) {
          try {
            ending.terminate();
          } catch (e) {
            if (_logger?.isInternal ?? false) {
              _logger?.internal(
                'Could not reset finished stream $streamId: $e',
              );
            }
          }
        }
        _streamSubscriptions.remove(streamId);
        _streamParsers.remove(streamId);
        _initialHeadersReceived.remove(streamId);
        _halfClosedLocal.remove(streamId);
        _reservedStreams.remove(streamId);
        _statusReceived.remove(streamId);
        // The one map this block used to leave behind, measured against the other
        // six: `releaseStreamId` was the only path that disposed a pump, so a
        // stream ending here kept one until its id was released -- which a direct
        // transport user need never do. Disposal also wakes anything parked on the
        // peer's window, which then fails rather than reporting a send that
        // cannot go anywhere.
        _outgoingPumps.remove(streamId)?.dispose();
      },
    );

    _streamSubscriptions[streamId] = subscription;
  }

  /// Dispatches one incoming frame to the headers or data handler.
  void _handleIncomingMessage(
    int streamId,
    http2.StreamMessage message,
    String methodPath,
  ) {
    try {
      if (message is http2.HeadersStreamMessage) {
        _handleHeadersMessage(streamId, message, methodPath);
      } else if (message is http2.DataStreamMessage) {
        _handleDataMessage(streamId, message, methodPath);
      }
    } catch (e, stackTrace) {
      _logger?.error(
        'Error handling a message on stream $streamId',
        error: e,
        stackTrace: stackTrace,
      );

      _emitStreamError(streamId, e, stackTrace: stackTrace);
      _dropFailedResponse(streamId);

      // A client is ground the same way a server is, and the shared layer
      // closes here too -- `RpcChannelTransport._validateInbound` runs on both
      // roles and the websocket CALLER inherits it. Only the backstop, NOT
      // `closeOnProtocolError`: the library's stated position for a client is
      // that killing the connection over one peer fault is the wrong answer,
      // because the other in-flight calls die with it (see
      // `closeOnOversizedFrame: !isClient`). A peer that has done it 256 times
      // is no longer one bad frame.
      //
      // `RpcMetadataViolation`, not `ArgumentError`: this closes a connection,
      // and ArgumentError means a programming mistake, so any of those raised
      // on this path was being charged to the peer's budget. See the same
      // narrowing on the responder.
      if (e is RpcMetadataViolation &&
          ++_policyViolations > _maxPolicyViolations) {
        _logger?.warning(
          'Peer sent $_policyViolations policy violations; closing',
        );
        unawaited(close());
      }
    }
  }

  /// The status [headers] carry, alone, or null if they carry none.
  ///
  /// Reads the RAW headers rather than converted metadata, which is this site's whole
  /// reason to exist: the converter refuses on `maxHeaders` partway through its walk,
  /// so by then there is nothing to read a status out of. What SURVIVES is
  /// `RpcSecurityPolicy.statusOnly`'s decision, not a second copy of it.
  RpcMetadata? _peerStatusOnly(List<http2.Header> headers) {
    final found = <RpcHeader>[];
    for (final header in headers) {
      final name = String.fromCharCodes(header.name);
      if (name == RpcHeaders.grpcStatus || name == RpcHeaders.grpcMessage) {
        found.add(RpcHeader(name, String.fromCharCodes(header.value)));
      }
    }
    return _policy.statusOnly(RpcMetadata(found));
  }

  /// Handles an incoming HEADERS frame (initial response or trailers).
  void _handleHeadersMessage(
    int streamId,
    http2.HeadersStreamMessage message,
    String methodPath,
  ) {
    // Check :status pseudo-header (present only in initial response, not trailers).
    final httpStatus = extractHttpStatus(message.headers);

    // An interim response (103 Early Hints): the final one follows on the same
    // stream, so failing here fails a call the server is about to answer.
    if (httpStatus != null && httpStatus >= 100 && httpStatus < 200) return;

    if (httpStatus != null && httpStatus != 200) {
      // Non-200 HTTP status — map through the gRPC status table.
      //
      // The mapping is not cosmetic: it decides whether the call is retryable.
      // Everything used to collapse to INTERNAL, which RetryInterceptor does
      // not retry, so a proxy answering 502/503/504 — or 429 while rate
      // limiting — produced a permanent failure where every other gRPC client
      // backs off and retries. See [grpcStatusFromHttpStatus].
      final grpcStatus = grpcStatusFromHttpStatus(httpStatus);
      _statusReceived.add(streamId);
      _logger?.warning(
        'Non-200 HTTP status $httpStatus for stream $streamId '
        '-> gRPC status $grpcStatus',
      );
      final errorMetadata = RpcMetadata([
        RpcHeader(RpcHeaders.grpcStatus, grpcStatus.toString()),
        RpcHeader(
          RpcHeaders.grpcMessage,
          RpcMetadata.encodeGrpcMessage('HTTP status $httpStatus'),
        ),
      ]);
      _emit(
        RpcTransportMessage(
          streamId: streamId,
          metadata: errorMetadata,
          isEndOfStream: true,
          methodPath: methodPath,
        ),
      );
      _dropFailedResponse(streamId);
      return;
    }

    // Track initial vs trailer headers.
    final isInitialHeaders = !_initialHeadersReceived.contains(streamId);
    if (isInitialHeaders) {
      _initialHeadersReceived.add(streamId);
    }

    // Pseudo-headers are filtered out by the converter.
    // A client is exposed to the same flood from the server it dialled.
    final RpcMetadata metadata;
    try {
      metadata = http2HeadersToRpcMetadata(message.headers, policy: _policy);
      _policy.validateMetadata(metadata);
    } on RpcMetadataViolation catch (violation) {
      // Our limits must not be able to destroy a status the PEER sent. Read from
      // the RAW headers, because the converter throws DURING its walk on
      // `maxHeaders` and never returns metadata to read the status out of.
      //
      // The frame is decoded and resident by the time this runs, so refusing it
      // buys no memory; it only decided whose answer ended the call. A grpc-go
      // server attaching 10 KiB of `grpc-status-details-bin` -- its rich error
      // model -- had FAILED_PRECONDITION replaced by our INVALID_ARGUMENT.
      final reduced = _peerStatusOnly(message.headers);
      if (reduced == null) rethrow;
      _logger?.warning(
        'Peer headers on stream $streamId violate the policy '
        '(${violation.message}); keeping their grpc-status and dropping the rest',
      );
      // Charged here because this path does not reach the catch that charges it,
      // and a peer that does this 256 times is not one rich error.
      if (++_policyViolations > _maxPolicyViolations) {
        _logger?.warning(
          'Peer sent $_policyViolations policy violations; closing',
        );
        unawaited(close());
      }
      _statusReceived.add(streamId);
      _emit(
        RpcTransportMessage(
          streamId: streamId,
          metadata: reduced,
          isEndOfStream: true,
          methodPath: methodPath,
        ),
      );
      return;
    }

    // Trailers-Only responses carry the status on the FIRST headers frame, so
    // key on the header rather than on the frame's position.
    if (metadata.getHeaderValue(RpcHeaders.grpcStatus) != null) {
      _statusReceived.add(streamId);
    }

    // A 200 whose content-type is not gRPC is not a gRPC response, and its body
    // is not gRPC frames. Without this check the parser met the raw bytes and
    // failed on whatever the first one happened to be: an HTML error page from
    // a proxy surfaced as `RpcException: Invalid compression flag in gRPC
    // message: 60` -- 60 being '<'. That is not an RpcStatusException at all,
    // so it carries no status code, callers that catch RpcStatusException miss
    // it entirely, and it names a framing detail instead of the problem.
    //
    // Checked only on the INITIAL headers: trailers legitimately carry no
    // content-type, so LENIENT is not a policy choice here -- an absent header
    // on a response is the ordinary case and refusing it would refuse every
    // Trailers-Only answer.
    if (isInitialHeaders) {
      final contentType = metadata.getHeaderValue(RpcHeaders.contentType);
      if (!RpcSecurityPolicy.isAcceptableContentType(
        contentType,
        RpcContentTypeValidation.lenient,
      )) {
        _logger?.warning(
          'Non-gRPC content-type "$contentType" for stream $streamId',
        );
        _statusReceived.add(streamId);
        _emit(
          RpcTransportMessage(
            streamId: streamId,
            metadata: RpcMetadata([
              RpcHeader(RpcHeaders.grpcStatus, RpcStatus.internal.toString()),
              RpcHeader(
                RpcHeaders.grpcMessage,
                RpcMetadata.encodeGrpcMessage(
                  'Invalid content-type for gRPC: "$contentType"',
                ),
              ),
            ]),
            isEndOfStream: true,
            methodPath: methodPath,
          ),
        );
        _dropFailedResponse(streamId);
        return;
      }
    }

    // Same rule as the DATA path below, and for the same reason: ending the
    // stream here closes the consumer FIRST, so the UNAVAILABLE that `onDone`
    // synthesises arrives after a clean end and is discarded. A trailers frame
    // carrying no grpc-status is exactly that case -- measured as
    // `CLEAN END after 2 item(s)` with the status arriving one message too late.
    //
    // A Trailers-Only response is unaffected: its status is on this very frame,
    // so `_statusReceived` is already set above.
    final statusKnown = _statusReceived.contains(streamId);
    final transportMessage = RpcTransportMessage(
      streamId: streamId,
      metadata: metadata,
      isEndOfStream: message.endStream && statusKnown,
      methodPath: methodPath,
    );

    _emit(transportMessage);
  }

  /// Parses an incoming DATA frame into gRPC messages and emits them.
  void _handleDataMessage(
    int streamId,
    http2.DataStreamMessage message,
    String methodPath,
  ) {
    try {
      // One parser per stream, created on first data.
      if (_streamParsers.length >= _policy.maxActiveStreams &&
          !_streamParsers.containsKey(streamId)) {
        // RESOURCE_EXHAUSTED: a limit that frees up as streams finish.
        throw RpcStatusException.atCapacity(
          'Too many active streams: ${_streamParsers.length} (max: ${_policy.maxActiveStreams})',
        );
      }
      final parser = _streamParsers.putIfAbsent(
        streamId,
        () => RpcMessageParser(
          logger: _logger?.child('Parser-$streamId'),
          maxMessageLength: _policy.maxMessageLengthBytes,
          maxBufferedBytes: _policy.maxBufferedBytes,
          maxMessagesPerChunk: _policy.maxMessagesPerChunk,
          // This transport hands FRAMES upward, so let the parser produce them.
          // It used to emit a body for an uncompressed message and a frame for a
          // compressed one, and the caller had to guess which -- from the bytes,
          // which the peer chooses. See `RpcMessageParser.emitFramed`.
          emitFramed: true,
        ),
      );

      // Decode the gRPC frame(s) in this chunk.
      final bytes = message.bytes is Uint8List
          ? message.bytes as Uint8List
          : Uint8List.fromList(message.bytes);
      final messages = parser(bytes);

      // END_STREAM belongs to the last message of the batch only, matched by
      // INDEX rather than by value: Uint8List compares by identity, which
      // breaks the moment the same reference appears twice.
      // A DATA frame carrying END_STREAM does NOT end the gRPC call unless a
      // status has already arrived.
      //
      // In gRPC over HTTP/2 the status travels in trailers -- a HEADERS frame
      // with END_STREAM -- so DATA never legitimately carries it. When a peer
      // ends the stream on DATA instead, the response is malformed, and the
      // `onDone` handler below synthesises the UNAVAILABLE that says so.
      //
      // Propagating END_STREAM here closed the consumer's stream FIRST, so that
      // synthesised error arrived after the consumer had already seen a clean
      // end and was discarded. Traced against a raw server sending two messages
      // and then END_STREAM with no trailers:
      //
      //   [transport] payload=true  end=true  grpc-status=-    <- closes it
      //   [transport] payload=false end=true  grpc-status=14   <- too late
      //   consumer: CLEAN END after 2 item(s), no error raised
      //
      // which is silent data loss: a client paging results believes it has them
      // all. This is the same failure 1a38a156 fixed for a connection that
      // DIES; `_statusReceived` was added then, but the end-of-stream flag on
      // the data path still short-circuited it for a peer that half-closes.
      final statusKnown = _statusReceived.contains(streamId);
      for (var i = 0; i < messages.length; i++) {
        // Already a frame: the parser was asked for frames.
        final framedMessage = messages[i];
        final transportMessage = RpcTransportMessage(
          streamId: streamId,
          payload: framedMessage,
          isEndOfStream:
              message.endStream && i == messages.length - 1 && statusKnown,
          methodPath: methodPath,
        );

        _emit(transportMessage);
      }

      if (_logger?.isInternal ?? false) {
        _logger?.internal(
          'Parsed ${messages.length} message(s) for stream $streamId',
        );
      }
    } catch (e, stackTrace) {
      _logger?.error(
        'Error decoding gRPC data for stream $streamId',
        error: e,
        stackTrace: stackTrace,
      );

      _emitStreamError(streamId, e, stackTrace: stackTrace);
      _dropFailedResponse(streamId);
    }
  }

  /// Routes an incoming message to the shared broadcast and to its own stream.
  void _emit(RpcTransportMessage message) {
    // Charge before delivering: a consumer that takes it synchronously
    // discharges immediately afterwards, and crediting a charge that has not
    // happened yet would clamp the counter at zero.
    _fcOnDelivered(message.streamId, message.payload?.length ?? 0);
    // A reset stream has had its last word: the overrun refusal above, or a
    // reset whose subscription cancel has not landed. Delivering this would
    // put data behind the error that ended the call.
    if (_resetStreams.contains(message.streamId)) return;
    if (!_messageController.isClosed) _messageController.add(message);
    _streams.add(message);
    if (message.isEndOfStream) _fcForget(message.streamId);
  }

  /// Routes a stream-scoped error: raw on the dedicated controller, enveloped
  /// on the broadcast (so it does not leak onto unrelated streams there).
  ///
  /// [connectionWide] for an error that means the connection failed; anything
  /// else is about this stream alone and goes out as [RpcHttp2OneStreamError].
  void _emitStreamError(
    int streamId,
    Object error, {
    StackTrace? stackTrace,
    bool connectionWide = false,
  }) {
    // A stream we reset on purpose reports the abort back to us. Surfacing it
    // would tell a consumer that deliberately cancelled that its own
    // cancellation was a transport failure.
    if (_resetStreams.contains(streamId)) {
      if (_logger?.isInternal ?? false) {
        _logger?.internal(
          'Suppressed an error for reset stream $streamId: $error',
        );
      }
      return;
    }
    _streams.addError(streamId, error, stackTrace);
    if (!_messageController.isClosed) {
      _messageController.addError(
        connectionWide
            ? RpcHttp2StreamError(streamId, error, stackTrace)
            : RpcHttp2OneStreamError(streamId, error, stackTrace),
      );
    }
  }
}
