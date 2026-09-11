// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';

import 'package:http2/http2.dart' as http2;
import 'package:rpc_dart/rpc_dart.dart';

import 'rpc_http2_common.dart';

/// Server-side HTTP/2 transport: one [IRpcTransport] over one connection,
/// multiplexing incoming RPC calls on the gRPC-compatible wire format.
///
/// Declares [IRpcSecurityPolicyAware] because the endpoint layers find the
/// policy with an `is` check: a transport that does not declare it silently
/// gets `const RpcSecurityPolicy()` instead of the configured one, so
/// `maxActiveStreams`, `halfOpenStreamTimeout` and the message-size limit all
/// revert to defaults.
class RpcHttp2ResponderTransport
    implements IRpcTransport, IRpcSecurityPolicyAware, IRpcFlowControlled {
  @override
  bool get isClient => false;

  @override
  RpcSecurityPolicy get securityPolicy => _policy;

  final http2.ServerTransportConnection _connection;

  final BufferedBroadcastController<RpcTransportMessage> _messageController =
      BufferedBroadcastController<RpcTransportMessage>(
        sizeOf: (m) => m.bufferedBytes,
      );

  /// Per-stream delivery for [getMessagesForStream]. The broadcast above is
  /// still fed so the responder pipeline can dispatch new incoming streams.
  final RpcStreamRouter _streams = RpcStreamRouter();

  /// Next outgoing stream id. The server side of HTTP/2 uses EVEN ids.
  int _nextStreamId = 2;

  /// Live client-initiated streams.
  final Map<int, http2.ServerTransportStream> _incomingStreams = {};

  /// Backpressured writers, one per outgoing stream. See [_OutgoingPump].
  final Map<int, _OutgoingPump> _outgoingPumps = {};

  /// Streams whose inbound crediting the responder pipeline has taken over.
  ///
  /// [IRpcFlowControlled] is how the pipeline says "I will report consumption
  /// myself". Without it declared here, the `deferFlowCredit` /
  /// `returnFlowCredit` calls `_pipelineFedRequestStream` already makes are
  /// silent no-ops: the demand signal exists and never reaches HTTP/2, so an
  /// upload into a handler consuming nothing climbs without ever plateauing.
  ///
  /// Note the shape that does NOT work here, since it is the obvious one:
  /// `onPause`/`onResume` on [getMessagesForStream]'s controller does nothing
  /// for uploads, because client-stream and bidi requests are fed by
  /// `_pipelineFedRequestStream` from the BROADCAST, not from that per-stream
  /// view. The pipeline's explicit credit calls are the only demand signal on
  /// this path.
  final Set<int> _fcDeferred = {};

  /// Bytes handed to a consumer but not yet reported consumed, per stream.
  final Map<int, int> _fcOutstanding = {};

  /// Streams already refused for overrunning [_fcWindow], so it is sent once.
  final Set<int> _fcRefused = {};

  /// How much un-consumed request payload one stream may hold.
  ///
  /// `flowControlWindowBytes` is the operator's existing knob for exactly this
  /// question. HTTP/2 carries its own windows, so this is not used to emit
  /// rpc-level grants; it is the threshold past which the CALL is refused.
  ///
  /// Do NOT make this the threshold at which reading stops — the obvious lever,
  /// and it makes every cancelled slow call destroy the CONNECTION.
  /// package:http2 credits the connection window only for messages it can move
  /// into a stream's queue, and it will not move them while that stream's
  /// consumer is paused, so a stalled call parks up to a whole connection
  /// window in `_stream2pendingMessages`; reset that stream and
  /// `_closeStreamAbnormally` drops the queue without ever calling
  /// `dataProcessed`, so no WINDOW_UPDATE is emitted for bytes the peer was
  /// charged for. One cancel exhausts the default 68 KiB connection window and
  /// every later call on it hangs.
  ///
  /// Refusing instead keeps reading, so the pool always flows, and bounds
  /// memory by ending the offending call. The cost, accepted by the owner: a
  /// handler that stops consuming kills its own call instead of being
  /// throttled.
  int get _fcWindow => unconsumedWindowFor(_policy);

  @override
  void deferFlowCredit(int streamId) => _fcDeferred.add(streamId);

  @override
  void returnFlowCredit(int streamId, int bytes) =>
      _fcDischarge(streamId, bytes);

  void _fcDischarge(int streamId, int bytes) {
    if (bytes <= 0) return;
    final left = (_fcOutstanding[streamId] ?? 0) - bytes;
    if (left <= 0) {
      _fcOutstanding.remove(streamId);
    } else {
      _fcOutstanding[streamId] = left;
    }
  }

  /// Charges [bytes] against [streamId]'s budget and refuses the call past it.
  ///
  /// Only for a stream whose consumer reports back — the pipeline through
  /// [returnFlowCredit], or a [getMessagesForStream] view through [_fcMetered].
  /// Charging anything else would never discharge, and a single unary request
  /// larger than the window would refuse itself.
  void _fcOnDelivered(int streamId, int bytes) {
    if (bytes <= 0) return;
    if (!_fcDeferred.contains(streamId) && !_streams.contains(streamId)) {
      return;
    }
    final now = (_fcOutstanding[streamId] ?? 0) + bytes;
    _fcOutstanding[streamId] = now;
    if (now > _fcWindow) _fcRefuseOverrun(streamId, now);
  }

  /// Ends a call whose consumer has stopped taking its request.
  void _fcRefuseOverrun(int streamId, int outstanding) {
    if (!_fcRefused.add(streamId)) return;
    _logger?.warning(
      'Stream $streamId holds $outstanding un-consumed request bytes '
      '(window: $_fcWindow); refusing the call',
    );
    // The status goes out FIRST, through the same pump as everything else, so
    // it is ordered ahead of the END_STREAM that teardown sends.
    unawaited(
      sendMetadata(
        streamId,
        RpcMetadata.forTrailer(
          RpcStatus.resourceExhausted,
          message:
              'Request exceeds the un-consumed window '
              '($outstanding > $_fcWindow bytes)',
          maxMessageLength: _policy.maxHeaderValueBytes,
        ),
        endStream: true,
      ).catchError((Object _) {}),
    );
    // Then tear the local call down through the same synthesized frame the
    // RST_STREAM path uses, so the handler stops rather than serving nobody.
    // Carries no payload, so it cannot re-enter _fcOnDelivered.
    _emit(
      RpcTransportMessage.withMetadata(
        streamId: streamId,
        metadata: RpcMetadata([
          RpcHeader(RpcHeaders.xClientCancelled, 'true'),
          RpcHeader(
            RpcHeaders.xCancellationReason,
            'un-consumed request window exceeded',
          ),
        ]),
      ),
    );
  }

  void _fcForget(int streamId) {
    _fcDeferred.remove(streamId);
    _fcOutstanding.remove(streamId);
    _fcRefused.remove(streamId);
  }

  final Map<int, StreamSubscription<void>> _streamSubscriptions = {};

  /// Per-stream frame parsers, which carry the state for a fragmented message.
  final Map<int, RpcMessageParser> _streamParsers = {};

  /// Streams whose initial response headers have gone out, which is what
  /// distinguishes trailers (no `:status`) from Trailers-Only (`:status` plus
  /// `grpc-status`).
  final Set<int> _initialHeadersSent = {};

  bool _isClosed = false;

  final LogScope? _logger;

  final RpcSecurityPolicy _policy;

  RpcHttp2ResponderTransport({
    required http2.ServerTransportConnection connection,
    RpcSecurityPolicy policy = const RpcSecurityPolicy(),
    LogScope? logger,
  }) : _connection = connection,
       _logger = logger?.child('Http2ServerTransport'),
       _policy = policy {
    _setupConnectionListener();
  }

  /// Subscribes to the connection's incoming client streams.
  void _setupConnectionListener() {
    _connection.incomingStreams.listen(
      _handleIncomingStream,
      onError: (Object error, StackTrace stackTrace) {
        _logger?.error(
          'HTTP/2 connection error',
          error: error,
          stackTrace: stackTrace,
        );

        if (!_messageController.isClosed) {
          _messageController.addError(error, stackTrace);
        }
      },
      onDone: () {
        // `incomingStreams` completing means NO MORE NEW STREAMS -- it does not
        // mean the connection is closed, and treating it as such killed every
        // call still running.
        //
        // package:http2 completes this stream from `onClosing()`, which fires
        // on GOAWAY (its `_finishing`) as well as on a real teardown. GOAWAY is
        // the ordinary graceful-shutdown signal -- a peer draining, a proxy
        // recycling a connection, a load balancer rotating a backend -- and its
        // whole point is that streams already open are allowed to FINISH.
        // Closing here answers "please stop starting new work" with "everything
        // in flight dies now", which also defeats this server's own drain.
        //
        // So: stop accepting, and close only once the last open stream is done.
        // A genuinely dead connection still closes promptly, because its
        // streams end too (and `socket.done` closes the endpoint regardless).
        _logger?.internal(
          'HTTP/2: no further incoming streams (GOAWAY or connection close)',
        );
        _acceptingStreams = false;
        _closeIfDrained();
      },
    );
  }

  /// False once the peer will send no further streams (GOAWAY or teardown).
  bool _acceptingStreams = true;

  /// Closes the transport once no stream is left to serve.
  ///
  /// Only meaningful after [_acceptingStreams] goes false: before that, an
  /// empty stream table is just an idle connection.
  void _closeIfDrained() {
    if (_acceptingStreams || _isClosed) return;
    if (_incomingStreams.isNotEmpty) return;
    _logger?.internal('HTTP/2: last stream drained, closing transport');
    close();
  }

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

        _emitStreamError(streamId, error, stackTrace);
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

      _emitStreamError(streamId, e, stackTrace);
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
        if (error is ArgumentError && _policy.closeOnProtocolError) {
          await _closeForProtocolError();
        }
      }
    }());
  }

  /// Ends the connection after a policy violation, when the policy asks for it.
  Future<void> _closeForProtocolError() async {
    if (_isClosed) return;
    try {
      await _connection.terminate();
    } catch (e) {
      _logger?.warning('Protocol-error close failed: $e');
    }
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
    if (requestMethod != null && requestMethod.toUpperCase() != 'POST') {
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
        throw RpcException(
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
        final framedMessage = ensureGrpcFrame(messages[i]);
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

      _emitStreamError(streamId, e, stackTrace);
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
  void _answerFramingViolation(int streamId, Object error) {
    // Every RpcException RpcMessageParser raises is a RESOURCE LIMIT, and all
    // four read as RESOURCE_EXHAUSTED to a gRPC peer:
    //   'gRPC frame buffer overflow: N (max: M)'
    //   'gRPC frame payload is too large: N (max: M)'
    //   'Decompressed gRPC payload is too large: N (max: M)'
    //   'Too many gRPC messages in a single chunk: N (max: M)'
    // Anything else reaching here is malformed framing, which is INTERNAL.
    //
    // Matched on the TYPE, never on message text: a text match for 'too large'
    // misses the buffer-overflow wording and the refusal comes back as
    // Internal.
    final status = error is RpcException
        ? RpcStatus.resourceExhausted
        : RpcStatus.internal;

    try {
      // The parser messages carry byte counts and limits ("gRPC frame payload
      // is too large: 2097160 bytes (max: 262144)"), so they run past a tight
      // `maxHeaderValueBytes` easily -- and the `catchError` below would then
      // swallow the answer entirely, leaving the peer with nothing for a
      // failure it could have corrected. Trimmed rather than risked.
      final trailers = RpcMetadata.forTrailer(
        status,
        message: '$error',
        maxMessageLength: _policy.maxHeaderValueBytes,
      );
      unawaited(
        sendMetadata(streamId, trailers, endStream: true).catchError((_) {}),
      );
    } catch (_) {
      // The stream may already be closed; the emitted error covers our side.
    }
  }

  @override
  int createStream() {
    if (_isClosed) throw StateError('Transport is closed');

    final streamId = _nextStreamId;
    _nextStreamId += 2; // Server ids are even: 2, 4, 6, ...

    // Server-push / server-initiated streams are NOT supported here. A minted
    // even id is not a real http2 stream, so any send on it would silently lose
    // data; the id is handed back for API compatibility and sends fail fast via
    // [_requireIncomingStream].
    if (_logger?.isInternal ?? false) {
      _logger?.internal('Created outgoing stream $streamId');
    }
    return streamId;
  }

  /// Returns the backpressured outgoing pump for [streamId], creating it on
  /// first use. Every outgoing frame for a stream MUST go through the same
  /// pump: mixing `sendHeaders`/`sendData` with the pump would reorder headers
  /// against data, which is a protocol error.
  _OutgoingPump _pumpFor(int streamId, http2.TransportStream stream) =>
      _outgoingPumps[streamId] ??= _OutgoingPump(stream);

  /// Resolves the http2 stream that a server-side send must target.
  ///
  /// Responder sends always reply on the client-initiated stream id (which is
  /// in [_incomingStreams]). An unknown id means either a server-initiated
  /// stream from [createStream] (unsupported) or a stale/released id — both are
  /// programming errors that must fail loudly instead of dropping data.
  http2.ServerTransportStream _requireIncomingStream(int streamId, String op) {
    final incomingStream = _incomingStreams[streamId];
    if (incomingStream == null) {
      throw StateError(
        'Cannot $op on stream $streamId: not a known incoming stream. '
        'Server-initiated streams are not supported on the HTTP/2 responder '
        '(server-push is unimplemented); responses must use the '
        'client-initiated stream id.',
      );
    }
    return incomingStream;
  }

  @override
  bool releaseStreamId(int streamId) {
    if (_isClosed) return false;

    if (_logger?.isInternal ?? false) {
      _logger?.internal('Releasing stream $streamId');
    }

    final incomingStream = _incomingStreams.remove(streamId);
    final pump = _outgoingPumps.remove(streamId);
    if (incomingStream != null) {
      try {
        // Through the pump when there is one: its addStream owns the sink, so
        // a direct sendData here would throw "cannot add while adding a
        // stream" and the release would fall through to terminate().
        if (pump != null) {
          pump.endStreamNow();
        } else {
          incomingStream.sendData(Uint8List(0), endStream: true);
        }
        if (_logger?.isInternal ?? false) {
          _logger?.internal('Sent END_STREAM releasing stream $streamId');
        }
      } catch (e) {
        if (_logger?.isInternal ?? false) {
          _logger?.internal(
            'Falling back to terminate on stream $streamId: $e',
          );
        }
        pump?.dispose();
        incomingStream.terminate();
      }
    } else {
      pump?.dispose();
    }

    final subscription = _streamSubscriptions.remove(streamId);
    subscription?.cancel();

    _streamParsers.remove(streamId);
    _initialHeadersSent.remove(streamId);
    _fcForget(streamId);

    // If the peer has already said it will send nothing further, this may have
    // been the last call we owed it.
    _closeIfDrained();

    return true;
  }

  @override
  Future<void> sendMetadata(
    int streamId,
    RpcMetadata metadata, {
    bool endStream = false,
  }) async {
    if (_isClosed) throw StateError('Transport is closed');

    // A response goes out on the client-initiated stream; an unknown id
    // (server-push) must fail loudly rather than silently drop the metadata.
    final incomingStream = _requireIncomingStream(streamId, 'send metadata');

    try {
      final List<http2.Header> headers;

      if (!endStream) {
        // Initial response headers — includes :status: 200
        headers = rpcMetadataToHttp2ResponseHeaders(metadata);
        _initialHeadersSent.add(streamId);
      } else if (!_initialHeadersSent.contains(streamId)) {
        // Trailers-Only — first and last HEADERS frame.
        // Must include :status: 200 and content-type per gRPC spec.
        headers = rpcMetadataToHttp2TrailersOnly(metadata);
        _initialHeadersSent.add(streamId);
      } else {
        // Trailers after initial headers + data.
        // MUST NOT include :status per HTTP/2 spec (RFC 7540 Section 8.1.2.1).
        headers = rpcMetadataToHttp2Trailers(metadata);
      }

      await _pumpFor(
        streamId,
        incomingStream,
      ).add(http2.HeadersStreamMessage(headers, endStream: endStream));

      if (_logger?.isInternal ?? false) {
        _logger?.internal(
          'Metadata sent for stream $streamId '
          '(${endStream ? (_initialHeadersSent.contains(streamId) ? "trailers" : "trailers-only") : "initial headers"})',
        );
      }
    } catch (e) {
      _logger?.error('Error sending metadata for stream $streamId: $e');
      rethrow;
    }
  }

  @override
  Future<void> sendMessage(
    int streamId,
    Uint8List data, {
    bool endStream = false,
  }) async {
    if (_isClosed) throw StateError('Transport is closed');

    final incomingStream = _requireIncomingStream(streamId, 'send message');

    try {
      assert(
        isGrpcFrame(data),
        'IRpcTransport.sendMessage expects a gRPC frame with a 5-byte prefix',
      );

      // Through the pump, so a peer that stops reading stops the handler --
      // `sendData` would enqueue regardless. See [_OutgoingPump].
      await _pumpFor(
        streamId,
        incomingStream,
      ).add(http2.DataStreamMessage(data, endStream: endStream));

      if (_logger?.isInternal ?? false) {
        _logger?.internal(
          'Sent ${data.length} response byte(s) for stream $streamId',
        );
      }
    } catch (e) {
      _logger?.error('Error sending data for stream $streamId: $e');
      rethrow;
    }
  }

  @override
  Future<void> finishSending(int streamId) async {
    if (_isClosed) return;

    final incomingStream = _incomingStreams[streamId];
    if (incomingStream == null) {
      if (_logger?.isInternal ?? false) {
        _logger?.internal(
          'Incoming stream $streamId not found, skipping finish sending',
        );
      }
      return;
    }

    try {
      // An empty DATA frame carrying END_STREAM.
      await _pumpFor(
        streamId,
        incomingStream,
      ).add(http2.DataStreamMessage(Uint8List(0), endStream: true));

      if (_logger?.isInternal ?? false) {
        _logger?.internal('Finished sending the response for stream $streamId');
      }
    } catch (e) {
      _logger?.warning('Error finishing the send for stream $streamId: $e');
    }
  }

  @override
  Stream<RpcTransportMessage> get incomingMessages => _messageController.stream;

  @override
  Stream<RpcTransportMessage> getMessagesForStream(int streamId) =>
      _fcMetered(streamId, _streams[streamId]);

  /// The OTHER half of the request-direction bound. Client-stream requests are
  /// fed by `_pipelineFedRequestStream`, which reports consumption through
  /// [IRpcFlowControlled]; bidirectional and server-stream ones are fed by
  /// `_stateBoundStream`, which subscribes HERE and never calls
  /// deferFlowCredit. Without a report from this side the bidi upload direction
  /// is unbounded even while client-stream is already bounded.
  ///
  /// `map` is lazy, so a consumer that stops pulling stops discharging, which
  /// is what lets the budget fill and the call be refused.
  Stream<RpcTransportMessage> _fcMetered(
    int streamId,
    Stream<RpcTransportMessage> source,
  ) => source.map((message) {
    _fcDischarge(streamId, message.payload?.length ?? 0);
    return message;
  });

  /// Routes an incoming message to the broadcast and to its own stream.
  void _emit(RpcTransportMessage message) {
    // Charge before delivering: the pipeline may consume synchronously and
    // report the credit back, and crediting a charge that has not happened yet
    // would leave the counter permanently negative-then-clamped at zero.
    _fcOnDelivered(message.streamId, message.payload?.length ?? 0);
    if (!_messageController.isClosed) _messageController.add(message);
    _streams.add(message);
  }

  /// Routes a stream-scoped error: raw on its own stream, enveloped on the
  /// broadcast.
  void _emitStreamError(int streamId, Object error, [StackTrace? stackTrace]) {
    _streams.addError(streamId, error, stackTrace);
    if (!_messageController.isClosed) {
      _messageController.addError(
        RpcHttp2StreamError(streamId, error, stackTrace),
      );
    }
  }

  Map<String, Object?> _buildHealthDetails() => {
    'isClosed': _isClosed,
    'incomingStreams': _incomingStreams.length,
    'streamSubscriptions': _streamSubscriptions.length,
    'streamParsers': _streamParsers.length,
    'messageControllerClosed': _messageController.isClosed,
  };

  @override
  Future<RpcHealthStatus> health() async {
    final details = _buildHealthDetails();

    if (_messageController.isClosed) {
      return RpcHealthStatus.closed(
        component: runtimeType.toString(),
        message: 'HTTP/2 responder transport closed',
        details: details,
      );
    }

    if (_isClosed) {
      return RpcHealthStatus.degraded(
        component: runtimeType.toString(),
        message: 'HTTP/2 responder connection is closed',
        details: details,
      );
    }

    return RpcHealthStatus.healthy(
      component: runtimeType.toString(),
      message: 'HTTP/2 responder ready',
      details: details,
    );
  }

  @override
  Future<RpcHealthStatus> reconnect() async {
    return RpcHealthStatus.degraded(
      component: runtimeType.toString(),
      message: 'Server-side HTTP/2 transport does not support manual reconnect',
      details: {..._buildHealthDetails(), 'supported': false},
    );
  }

  @override
  Future<void> close() async {
    if (_isClosed) return;

    _logger?.info('Closing the HTTP/2 responder transport');
    _isClosed = true;

    // A short grace period for streams still finishing.
    final totalStreams = _incomingStreams.length;
    if (totalStreams > 0) {
      if (_logger?.isInternal ?? false) {
        _logger?.internal('Waiting on $totalStreams active stream(s)');
      }
      await Future<void>.delayed(Duration(milliseconds: 50));
    }

    for (final stream in _incomingStreams.values) {
      try {
        // Soft close, via the pump where one exists: it owns the sink, and it
        // also releases any handler parked on the peer's window so teardown
        // does not wait on a dead reader.
        final pump = _outgoingPumps[stream.id];
        if (pump != null) {
          pump.endStreamNow();
        } else {
          stream.sendData(Uint8List(0), endStream: true);
        }
        if (_logger?.isInternal ?? false) {
          _logger?.internal('Sent END_STREAM for stream ${stream.id}');
        }
      } catch (e) {
        if (_logger?.isInternal ?? false) {
          _logger?.internal(
            'Falling back to terminate on stream ${stream.id}: $e',
          );
        }
        try {
          stream.terminate();
        } catch (e2) {
          _logger?.warning('Error terminating stream ${stream.id}: $e2');
        }
      }
    }
    _incomingStreams.clear();

    // Release anything still parked on a peer window, after the soft close
    // above has had its chance to flush.
    for (final pump in _outgoingPumps.values) {
      pump.dispose();
    }
    _outgoingPumps.clear();

    for (final subscription in _streamSubscriptions.values) {
      await subscription.cancel();
    }
    _streamSubscriptions.clear();

    _streamParsers.clear();
    _initialHeadersSent.clear();
    _fcDeferred.clear();
    _fcOutstanding.clear();

    _streams.closeAll();

    await _connection.finish();

    if (!_messageController.isClosed) {
      await _messageController.close();
    }

    _logger?.info('HTTP/2 responder transport closed');
  }

  @override
  bool get isClosed => _isClosed;

  @override
  Future<void> sendDirectObject(
    int streamId,
    Object object, {
    bool endStream = false,
  }) async {
    throw UnimplementedError('Unsupport direct object sending');
  }

  @override
  bool get supportsZeroCopy => false;
}

/// The backpressured writer, shared with the caller transport, which needs the
/// same thing for the request direction. See [RpcHttp2OutgoingPump].
///
/// Why this transport cannot fall back to the rpc-level window instead: that one
/// rides on `x-window-update` metadata frames, which a real gRPC client would
/// read as trailers. HTTP/2 has native windows and sets the rpc-level one to
/// null, so bypassing the native one leaves nothing at all.
typedef _OutgoingPump = RpcHttp2OutgoingPump;
