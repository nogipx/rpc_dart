// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

part of 'rpc_http2_responder_transport.dart';

/// How many policy violations a connection may cost before it is treated as
/// hostile rather than misconfigured.
///
/// The same backstop, and the same 256, as `RpcChannelTransport`: the field
/// defaulting to false says one bad frame must not end the connection, NOT
/// that a peer may grind forever. Measured here at the default policy, 2000
/// violating header blocks were all accepted with the connection still open
/// and RSS up 27 MiB, against a shared-layer control that closed after 256.
const int _maxPolicyViolations = 256;

extension _Http2ResponderInbound on RpcHttp2ResponderTransport {
  /// Wires up one new client-initiated stream.
  void _handleIncomingStream(http2.ServerTransportStream stream) {
    final streamId = stream.id;
    _incomingStreams[streamId] = stream;
    if (_logger?.isInternal ?? false) {
      _logger?.internal(
        'New incoming stream $streamId (active: ${_incomingStreams.length})',
      );
    }

    final subscription = stream.incomingMessages.listen(
      (http2.StreamMessage message) {
        _handleIncomingMessage(streamId, message);
      },
      onError: (Object error, StackTrace stackTrace) {
        // A peer RST_STREAM is a cancellation, not a transport fault: the
        // client walked away (a cancelled subscription, a deadline). Reporting
        // it as a stream error pushes an RpcHttp2StreamError at every
        // incomingMessages consumer for what is a routine event. Surface it as
        // a clean end-of-stream instead, which is also what lets the responder
        // tear the call down and stop the handler.
        if (error is http2.StreamTransportException) {
          if (_logger?.isInternal ?? false) {
            _logger?.internal(
              'Stream $streamId reset by peer: ${error.message}',
            );
          }
          _emit(RpcTransportMessage(streamId: streamId, isEndOfStream: true));
          return;
        }

        _logger?.error(
          'Error on stream $streamId',
          error: error,
          stackTrace: stackTrace,
        );

        _emitStreamError(
          streamId,
          error,
          stackTrace: stackTrace,
          connectionWide: true,
        );
      },
      onDone: () {
        if (_logger?.isInternal ?? false) {
          _logger?.internal('Incoming stream $streamId ended');
        }
        _emit(RpcTransportMessage(streamId: streamId, isEndOfStream: true));

        // NOT removed from _incomingStreams here: the response still has to go
        // out on it. releaseStreamId or close() reclaims it.
        _streamSubscriptions.remove(streamId);
        _streamParsers.remove(streamId);
      },
    );

    _streamSubscriptions[streamId] = subscription;

    // RST_STREAM after the request side has finished has NOWHERE else to land.
    //
    // The onError branch above catches a reset only while `incomingMessages` is
    // still live. For a server-stream or unary call the client half-closes as
    // soon as its request is out, so `onDone` has already run and the
    // subscription is gone by the time the client cancels -- and package:http2
    // reports the reset only through `onTerminated`. Leave that unregistered
    // and the call runs to completion with no client at all: the handler keeps
    // producing indefinitely with its stream slot held.
    //
    // Synthesising the same `x-client-cancelled` frame the websocket sibling
    // sends reuses that tested teardown path rather than adding a second one.
    stream.onTerminated = (errorCode) {
      if (_logger?.isInternal ?? false) {
        _logger?.internal(
          'Stream $streamId reset by peer (errorCode: $errorCode), '
          'cancelling the call',
        );
      }
      _emit(
        RpcTransportMessage.withMetadata(
          streamId: streamId,
          metadata: RpcMetadata([
            RpcHeader(RpcHeaders.xClientCancelled, 'true'),
            RpcHeader(
              RpcHeaders.xCancellationReason,
              'peer sent RST_STREAM (errorCode: $errorCode)',
            ),
          ]),
        ),
      );
    };
  }

  /// Dispatches one incoming frame to the headers or data handler.
  void _handleIncomingMessage(int streamId, http2.StreamMessage message) {
    try {
      if (message is http2.HeadersStreamMessage) {
        _handleIncomingHeaders(streamId, message);
      } else if (message is http2.DataStreamMessage) {
        _handleIncomingData(streamId, message);
      }
    } catch (e, stackTrace) {
      _logger?.error(
        'Error handling a message on stream $streamId',
        error: e,
        stackTrace: stackTrace,
      );

      _emitStreamError(streamId, e, stackTrace: stackTrace);
      _answerRejectedStream(streamId, e);
    }
  }

  /// Answers a request this transport refused before the pipeline ever saw it.
  ///
  /// A header frame that fails [RpcSecurityPolicy.validateMetadata] throws out
  /// of [_handleIncomingHeaders] BEFORE [_emit], so the responder pipeline gets
  /// no state for the stream and never replies. Without this the peer waits
  /// forever and the HTTP/2 stream stays in [_incomingStreams] — and since the
  /// peer chooses the `:path`, that is an unauthenticated way to pin
  /// `maxActiveStreams` worth of slots with requests that can never complete.
  ///
  /// [_emitStreamError] alone does not help: it reports inward, to a pipeline
  /// with nothing to attach the error to.
  ///
  /// Sent as Trailers-Only (the stream has no initial headers yet), and
  /// detached with its own guard, because this runs on the connection's listen
  /// callback where a throw would reach the root zone.
  void _answerRejectedStream(int streamId, Object error) {
    if (_isClosed) return;
    if (!_incomingStreams.containsKey(streamId)) return;

    final status = error is ArgumentError
        ? RpcStatus.invalidArgument
        : RpcStatus.internal;
    final message = error is ArgumentError
        ? (error.message?.toString() ?? 'Invalid request metadata')
        : 'Request rejected: $error';

    unawaited(() async {
      try {
        await sendMetadata(
          streamId,
          // Trimmed to the policy this trailer is validated against on the way
          // out: `grpc-message` is a header value, so a rejection long enough to
          // explain itself could fail the same check that produced it, and the
          // catch below would swallow the whole answer.
          RpcMetadata.forTrailer(
            status,
            message: message,
            maxMessageLength: _policy.maxHeaderValueBytes,
          ),
          endStream: true,
        );
      } on ArgumentError catch (e) {
        // The REFUSAL ITSELF violated the policy that produced it. Trimming the
        // message covers `maxHeaderValueBytes` and not `maxHeaders`: this
        // trailer carries grpc-status AND grpc-message, so a cap below 2
        // refuses the refusal, and the peer was told "connection lost or
        // stream reset before trailers" -- UNAVAILABLE, which reads as
        // retryable -- for a deterministic policy rejection it should retry
        // never.
        //
        // The status survives and the text gives way, the same trade the
        // message trimming above already makes.
        _logger?.warning(
          'Refusal for stream $streamId does not fit the policy ($e); '
          'sending the status alone',
        );
        try {
          await sendMetadata(
            streamId,
            RpcMetadata.forTrailer(status),
            endStream: true,
          );
        } catch (e2) {
          _logger?.warning('Could not reject stream $streamId: $e2');
        }
      } catch (e) {
        _logger?.warning('Could not reject stream $streamId: $e');
      } finally {
        releaseStreamId(streamId);
        // `closeOnProtocolError` must be honoured HERE too, not only in
        // RpcChannelTransport: HTTP/2 is the transport a gRPC deployment
        // actually exposes, and a security knob that silently does nothing on
        // the transport you deployed is worse than one that is absent.
        //
        // Answered FIRST, then closed: the peer has to learn it was its own
        // fault, or a plain disconnect reads as UNAVAILABLE and is retried.
        // Same order as the channel transport's protocol close.
        //
        // `RpcMetadataViolation`, not `ArgumentError`. This decides whether to
        // END A CONNECTION, and `ArgumentError` means "a caller passed a bad
        // argument" — a programming mistake. Any such error raised anywhere on
        // this path was being charged to the peer's 256-strike budget as if it
        // were hostile. The narrower type is the one `validateMetadata` throws,
        // and it still IS an ArgumentError, so nothing else had to change.
        if (error is RpcMetadataViolation &&
            (_policy.closeOnProtocolError ||
                ++_policyViolations > _maxPolicyViolations)) {
          await _closeForProtocolError();
        }
      }
    }());
  }

  /// Converts a request's HEADERS frame into metadata and emits it.
  void _handleIncomingHeaders(
    int streamId,
    http2.HeadersStreamMessage message,
  ) {
    // gRPC is POST-only. Without this check EVERY method runs the handler, and
    // GET is the one that matters: a browser can be made to issue a
    // cross-origin GET without a preflight, while a POST carrying
    // `content-type: application/grpc` cannot leave the origin unprompted -- so
    // accepting GET turns every unary method into something an attacker's page
    // can trigger. HEAD and the rest are the same hole, less reachable.
    //
    // Only a FOREIGN peer chooses the method (rpc_dart's own caller hard-codes
    // POST in rpcMetadataToHttp2RequestHeaders), so nothing in this library's
    // own tests reaches it.
    //
    // Absent is left alone rather than rejected, matching the content-type
    // check next door: a request with no `:method` is malformed HTTP/2 and
    // package:http2 refuses it before this point.
    final requestMethod = extractRequestMethod(message.headers);
    // Exact: HTTP methods are case-sensitive (RFC 9110 §9.1), so `post` is
    // not POST.
    if (requestMethod != null && requestMethod != 'POST') {
      throw ArgumentError.value(
        requestMethod,
        ':method',
        'gRPC requires POST; this request used a different HTTP method',
      );
    }

    final methodPath = extractMethodPath(message.headers);

    final metadata = http2HeadersToRpcMetadata(
      message.headers,
      methodPath: methodPath,
      // Enforced DURING the walk, not after it: see the converter. The
      // validateMetadata below still runs and still owns every other rule.
      policy: _policy,
    );
    _policy.validateMetadata(metadata);

    _emit(
      RpcTransportMessage(
        streamId: streamId,
        metadata: metadata,
        isEndOfStream: message.endStream,
        methodPath: methodPath,
      ),
    );

    if (_logger?.isInternal ?? false) {
      _logger?.internal('Headers received for stream $streamId: $methodPath');
    }
  }

  /// Parses a request's DATA frame into gRPC messages and emits them.
  void _handleIncomingData(int streamId, http2.DataStreamMessage message) {
    try {
      if (_streamParsers.length >= _policy.maxActiveStreams &&
          !_streamParsers.containsKey(streamId)) {
        // RESOURCE_EXHAUSTED: a limit that frees up. It reaches the peer
        // through _answerFramingViolation, which now takes the status from the
        // error rather than guessing from the base class.
        throw RpcStatusException(
          RpcStatus.resourceExhausted,
          'Too many active streams: ${_streamParsers.length} (max: ${_policy.maxActiveStreams})',
        );
      }
      final parser = _streamParsers.putIfAbsent(
        streamId,
        () => RpcMessageParser(
          logger: _logger?.child('Parser-$streamId'),
          maxMessageLength: _policy.maxMessageLengthBytes,
          maxBufferedBytes: _policy.maxBufferedBytes,
          // Frames upward, so the parser makes them. See the caller transport and
          // `RpcMessageParser.emitFramed`.
          emitFramed: true,
          maxMessagesPerChunk: _policy.maxMessagesPerChunk,
        ),
      );

      final bytes = message.bytes is Uint8List
          ? message.bytes as Uint8List
          : Uint8List.fromList(message.bytes);
      final messages = parser(bytes);

      // END_STREAM belongs to the last message of the batch only, matched by
      // INDEX rather than by value: Uint8List compares by identity, which
      // breaks the moment the same reference appears twice.
      for (var i = 0; i < messages.length; i++) {
        // Already a frame: the parser was asked for frames.
        final framedMessage = messages[i];
        final transportMessage = RpcTransportMessage(
          streamId: streamId,
          payload: framedMessage,
          isEndOfStream: message.endStream && i == messages.length - 1,
        );

        _emit(transportMessage);
      }

      if (_logger?.isInternal ?? false) {
        _logger?.internal(
          'Parsed ${messages.length} incoming message(s) for stream $streamId',
        );
      }
    } catch (e, stackTrace) {
      _logger?.error(
        'Error decoding incoming gRPC data for stream $streamId',
        error: e,
        stackTrace: stackTrace,
      );

      _emitStreamError(streamId, e, stackTrace: stackTrace);
      _answerFramingViolation(streamId, e);
    }
  }

  /// Answers a peer whose frame this transport refused to decode.
  ///
  /// [_emitStreamError] tells OUR side only. The offending frame is dropped, so
  /// without this the stream reaches the responder pipeline carrying no payload
  /// and the peer gets whatever the pipeline makes of an empty request — an
  /// INVALID_ARGUMENT about a missing payload, which names a symptom instead of
  /// the cause.
  ///
  /// gRPC answers an over-limit message with RESOURCE_EXHAUSTED (grpc-go and
  /// grpc-java both do), and the distinction inverts retry semantics:
  /// RpcRetryInterceptor treats RESOURCE_EXHAUSTED as transient and
  /// INVALID_ARGUMENT as final.
  ///
  /// Best-effort: if the stream is already gone, or headers cannot be sent,
  /// there is nothing further to do and the local error above still stands.
  ///
  /// Released afterwards, for the reason [_answerRejectedStream] gives: the
  /// refusal is the last thing this stream will ever carry, and a frame that
  /// fails the parser leaves the pipeline nothing to reply with, so nobody else
  /// will call [releaseStreamId]. Whether the peer half-closed is the peer's
  /// choice, and that is not a choice the server's bookkeeping may depend on.
  void _answerFramingViolation(int streamId, Object error) {
    // The status comes from the ERROR, because the error knows.
    //
    // This used to read `error is RpcException ? resourceExhausted : internal`
    // and enumerate the parser's four limits by hand. The intent was right and
    // the discriminator could not express it: `RpcException` is the BASE of the
    // hierarchy, so `RpcMessageFrame.parseHeader`'s MALFORMED-framing throws —
    // raised on this very path — matched it too. Measured, one prefix apart:
    //
    //   limit      grpc-status 8  "payload is too large: 33554432 (max: ...)"
    //   malformed  grpc-status 8  "Invalid compression flag in gRPC message: 2"
    //
    // and RESOURCE_EXHAUSTED is retryable, so a corrupt frame was answered
    // "try again". The parser now carries its own status, so asking
    // wireStatusFor is both correct and shorter.
    //
    // It also closes a leak the old code had: the message below was `'$error'`
    // UNCONDITIONALLY, so a foreign error's text went to the peer. wireStatusFor
    // is default-deny and redacts anything that is not ours.
    final wire = wireStatusFor(error);
    final status = wire.status;

    unawaited(() async {
      try {
        // The parser messages carry byte counts and limits ("gRPC frame payload
        // is too large: 2097160 bytes (max: 262144)"), so they run past a tight
        // `maxHeaderValueBytes` easily -- and the catch below would then swallow
        // the answer entirely, leaving the peer with nothing for a failure it
        // could have corrected. Trimmed rather than risked.
        final trailers = RpcMetadata.forTrailer(
          status,
          message: wire.message,
          maxMessageLength: _policy.maxHeaderValueBytes,
        );
        await sendMetadata(streamId, trailers, endStream: true);
      } catch (_) {
        // The stream may already be closed; the emitted error covers our side.
      } finally {
        // A handler already running on this id has to stop, the way
        // [_fcRefuseOverrun] stops one: the error above reaches its request
        // stream, but nothing CLOSES that stream, so an upload handler sits in
        // its `await for` forever. Independently load-bearing — ablating this
        // alone leaves the counters at zero and the handler live.
        _emit(
          RpcTransportMessage.withMetadata(
            streamId: streamId,
            metadata: RpcMetadata([
              RpcHeader(RpcHeaders.xClientCancelled, 'true'),
              RpcHeader(RpcHeaders.xCancellationReason, 'frame refused'),
            ]),
          ),
        );
        releaseStreamId(streamId);

        // A frame this transport cannot DECODE is a protocol violation in the
        // sense `closeOnProtocolError` documents, so it is accounted for the
        // same way as its header-level sibling `_answerRejectedStream`.
        //
        // RESOURCE_EXHAUSTED is excluded and must stay excluded: that peer is
        // not broken, it is misconfigured. A client with a larger send limit
        // than the server's receive limit hits it on EVERY call, and it is told
        // RESOURCE_EXHAUSTED precisely so it can correct itself and retry --
        // counting it would end that client's connection every 256 calls.
        //
        // The status is the discriminator because round 412 made it one. This
        // site used to read `error is RpcException`, which is the BASE of the
        // hierarchy and matched both kinds; now a limit says 8 and malformed
        // framing says 13, one prefix apart, and the two can finally be told
        // apart at all.
        if (status != RpcStatus.resourceExhausted &&
            (_policy.closeOnProtocolError ||
                ++_policyViolations > _maxPolicyViolations)) {
          await _closeForProtocolError();
        }
      }
    }());
  }

  /// Routes an incoming message to the broadcast and to its own stream.
  void _emit(RpcTransportMessage message) {
    // Charge before delivering: the pipeline may consume synchronously and
    // report the credit back, and crediting a charge that has not happened yet
    // would leave the counter permanently negative-then-clamped at zero.
    _fcOnDelivered(message.streamId, message.payload?.length ?? 0);
    // A refused call has been cancelled; its payload, the overrunning one
    // included, must not reach the handler behind the cancellation.
    if (message.payload != null && _fcRefused.contains(message.streamId)) {
      return;
    }
    if (!_messageController.isClosed) _messageController.add(message);
    _streams.add(message);
  }

  /// Routes a stream-scoped error: raw on its own stream, enveloped on the
  /// broadcast.
  ///
  /// [connectionWide] for an error that means the connection failed; anything
  /// else is about this stream alone and goes out as [RpcHttp2OneStreamError].
  void _emitStreamError(
    int streamId,
    Object error, {
    StackTrace? stackTrace,
    bool connectionWide = false,
  }) {
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
