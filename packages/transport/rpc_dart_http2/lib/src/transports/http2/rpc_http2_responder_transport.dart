// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';

import 'package:http2/http2.dart' as http2;
import 'package:rpc_dart/transport.dart';

import 'http2_flow_ledger.dart';
import 'http2_header_block_guard.dart';
import 'http2_write_backlog.dart';
import 'rpc_http2_common.dart';

part 'rpc_http2_responder_transport_flow.dart';
part 'rpc_http2_responder_transport_inbound.dart';
part 'rpc_http2_responder_transport_lifecycle.dart';
part 'rpc_http2_responder_transport_stream.dart';

/// Server-side HTTP/2 transport: one [IRpcTransport] over one connection,
/// multiplexing incoming RPC calls on the gRPC-compatible wire format.
///
/// Grants no message credit: HTTP/2 paces a peer by its own byte windows, so
/// the responder bounds request queues by bytes alone.
class RpcHttp2ResponderTransport extends IRpcTransport
    implements IRpcFlowCredit {
  @override
  bool get isClient => false;

  @override
  RpcSecurityPolicy get securityPolicy => _policy;

  @override
  bool get grantsMessageCredit => false;

  @override
  IRpcFlowCredit get flowCredit => this;

  @override
  int get lastIssuedStreamId => _nextStreamId - 2;

  @override
  bool get supportsStreamIdResume => true;

  @override
  void resumeStreamIdsAfter(int streamId) {
    // Server ids are even; a wrong-parity value rounds UP. Forward only.
    final aligned = streamId.isEven ? streamId : streamId + 1;
    if (aligned + 2 > _nextStreamId) _nextStreamId = aligned + 2;
  }

  final http2.ServerTransportConnection _connection;

  /// The connection this transport speaks over.
  ///
  /// Exposed for the lifecycle a transport does not own — keepalive PINGs and
  /// shutdown — which the server drives. No new surface: the type is already
  /// public on the constructor, and [RpcHttp2ResponderTransport.overStreams]
  /// builds one the caller would otherwise never see.
  http2.ServerTransportConnection get connection => _connection;

  final RpcBufferedBroadcastController<RpcTransportMessage> _messageController =
      RpcBufferedBroadcastController<RpcTransportMessage>(
        sizeOf: (m) => m.bufferedBytes,
      );

  /// Per-stream delivery for [getMessagesForStream]. The broadcast above is
  /// still fed so the responder pipeline can dispatch new incoming streams.
  final RpcStreamRouter _streams = RpcStreamRouter();

  /// Next outgoing stream id. The server side of HTTP/2 uses EVEN ids.
  int _nextStreamId = 2;

  /// Live client-initiated streams; see [_ResponderStream].
  final Map<int, _ResponderStream> _calls = {};

  final _ParserTally _parsers = _ParserTally();

  /// How many calls [test] holds for.
  int _count(bool Function(_ResponderStream call) test) =>
      _calls.values.where(test).length;

  /// The un-consumed REQUEST bound; see [_Http2ResponderFlow].
  ///
  /// Charged only for a stream whose consumer reports back: the pipeline,
  /// once it has deferred the stream's credit, or a [getMessagesForStream]
  /// view, which discharges through [Http2FlowLedger.metered]. Charging
  /// anything else would never discharge, and a single unary request larger
  /// than the window would refuse itself.
  late final Http2FlowLedger _fc = Http2FlowLedger(
    policy: _policy,
    accountOf: (streamId) => _calls[streamId]?.flow,
    isMetered: (streamId, account) =>
        account.deferred || _streams.contains(streamId),
    onOverrun: _fcRefuseOverrun,
  );

  /// The pipeline takes over this stream's inbound crediting.
  ///
  /// [flowCredit] is how the pipeline says "I will report consumption
  /// myself". Without it here, the `deferFlowCredit` /
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
  @override
  void deferFlowCredit(int streamId) => _calls[streamId]?.flow.deferred = true;

  @override
  void returnFlowCredit(int streamId, int bytes) =>
      _fc.discharge(streamId, bytes);

  bool _isClosed = false;

  final LogScope _log;

  final RpcSecurityPolicy _policy;

  /// Wraps a connection you built yourself.
  ///
  /// This constructor cannot enforce the parts of [policy] that live BELOW
  /// package:http2 — the header-block bound, the write backlog bound and the
  /// advertised MAX_CONCURRENT_STREAMS are properties of how the connection was
  /// built, and by here it already is. Prefer
  /// [RpcHttp2ResponderTransport.overStreams], which applies all three; see its
  /// note for what this one leaves off.
  RpcHttp2ResponderTransport({
    required http2.ServerTransportConnection connection,
    RpcSecurityPolicy policy = const RpcSecurityPolicy(),
    LogScope? logger,
  }) : _connection = connection,
       _log = logger?.child('Http2ServerTransport') ?? LogScope.noop,
       _policy = policy {
    _setupConnectionListener();
  }

  /// Builds the connection from a socket's streams AND applies the parts of
  /// [policy] that package:http2 cannot be told after the fact.
  ///
  /// Three of them, all invisible once the connection exists:
  ///
  /// * the **write backlog bound**. package:http2 reads on whatever it cannot
  ///   write, so past [RpcWriteBacklog.defaultServerMax] unsent this stops
  ///   reading the peer until half of it has gone out.
  /// * the **header-block bound**. package:http2 concatenates a HEADERS frame
  ///   and its CONTINUATION frames with no limit and an O(N^2) recopy, below
  ///   every rpc_dart limit because no stream is created until END_HEADERS.
  /// * the **advertised MAX_CONCURRENT_STREAMS**. Without it every connection
  ///   announces package:http2's default of 1000 whatever the policy says, so
  ///   `maxActiveStreams` below that refuses streams a conforming client was
  ///   invited to open, and above it does nothing at all.
  ///
  /// [destroy] is called when the peer breaches the header-block bound; it must
  /// tear the socket down, because there is no answering a flood that never
  /// finished its headers.
  factory RpcHttp2ResponderTransport.overStreams({
    required Stream<List<int>> incoming,
    required StreamSink<List<int>> outgoing,
    required void Function() destroy,
    RpcSecurityPolicy policy = const RpcSecurityPolicy(),
    LogScope? logger,
    void Function(int observedBytes)? onHeaderBlockViolation,
    void Function()? onPrefaceComplete,
  }) {
    // Without it a peer that reads nothing and keeps opening calls answered by
    // a trailer alone grows the server's write queue without end.
    final backlog = Http2WriteBacklog(
      outgoing,
      maxUnsentBytes: RpcWriteBacklog.defaultServerMax,
    );
    final guarded = guardHttp2HeaderBlock(
      backlog.reads(incoming),
      maxHeaderBlockBytes: policy.maxMetadataBytes,
      onViolation: (observedBytes) {
        logger?.warning(
          'HTTP/2 header-block cap exceeded: $observedBytes bytes '
          '(max: ${policy.maxMetadataBytes}); closing connection',
        );
        onHeaderBlockViolation?.call(observedBytes);
        destroy();
      },
      onPrefaceComplete: onPrefaceComplete,
    );

    return RpcHttp2ResponderTransport(
      connection: http2.ServerTransportConnection.viaStreams(
        guarded,
        backlog.writes,
        // CLAMPED. SETTINGS_MAX_CONCURRENT_STREAMS is a uint32 and
        // RpcSecurityPolicy asserts nothing, so the field holds whatever an
        // operator typed — and unclamped both ends of the range go on the wire
        // INVERTED: a negative limit wraps to 4294967295, announcing "unlimited"
        // while the pipeline refuses every stream; anything at or above 2^32
        // truncates to 0, announcing "open nothing" while the server would
        // happily serve billions. Clamping keeps the invariant that matters —
        // never announce MORE than will be honoured. Validating the field in
        // RpcSecurityPolicy itself is the other half, and is a core semantics
        // decision (is `0` a legitimate way to say "accept nothing"?), so it is
        // left to the owner.
        settings: http2.ServerSettings(
          concurrentStreamLimit: policy.maxActiveStreams.clamp(0, 0xFFFFFFFF),
        ),
      ),
      policy: policy,
      logger: logger,
    );
  }

  /// False once the peer will send no further streams (GOAWAY or teardown).
  bool _acceptingStreams = true;

  int _policyViolations = 0;

  @override
  int createStream() {
    if (_isClosed) throw RpcClosedException('Transport');

    final streamId = _nextStreamId;
    _nextStreamId += 2; // Server ids are even: 2, 4, 6, ...

    // Server-push / server-initiated streams are NOT supported here. A minted
    // even id is not a real http2 stream, so any send on it would silently lose
    // data; the id is handed back for API compatibility and sends fail fast via
    // [_requireIncomingStream].
    if (_log.isInternal) {
      _log.internal('Created outgoing stream $streamId');
    }
    return streamId;
  }

  /// Returns the backpressured outgoing pump for [streamId], creating it on
  /// first use. Every outgoing frame for a stream MUST go through the same
  /// pump: mixing `sendHeaders`/`sendData` with the pump would reorder headers
  /// against data, which is a protocol error.
  _OutgoingPump _pumpFor(_ResponderStream call) =>
      call.pump ??= _OutgoingPump(call.incoming);

  /// Resolves the client-initiated stream that a server-side send must target.
  ///
  /// Responder sends always reply on the client-initiated stream id (which is
  /// in [_calls]). An unknown id means either a server-initiated stream from
  /// [createStream] (unsupported) or a stale/released id — both are
  /// programming errors that must fail loudly instead of dropping data.
  _ResponderStream _requireIncomingStream(int streamId, String op) {
    final call = _calls[streamId];
    if (call == null) {
      throw RpcStatusException(
        RpcStatus.unimplemented,
        'Cannot $op on stream $streamId: not a known incoming stream. '
        'Server-initiated streams are not supported on the HTTP/2 responder '
        '(server-push is unimplemented); responses must use the '
        'client-initiated stream id.',
      );
    }
    return call;
  }

  @override
  bool releaseStreamId(int streamId) {
    if (_isClosed) return false;

    if (_log.isInternal) {
      _log.internal('Releasing stream $streamId');
    }

    final call = _calls.remove(streamId);
    if (call != null) {
      final pump = call.pump;
      call.pump = null;
      try {
        // Through the pump when there is one: its addStream owns the sink, so
        // a direct sendData here would throw "cannot add while adding a
        // stream" and the release would fall through to terminate().
        if (pump != null) {
          pump.endStreamNow();
        } else {
          call.incoming.sendData(Uint8List(0), endStream: true);
        }
        if (_log.isInternal) {
          _log.internal('Sent END_STREAM releasing stream $streamId');
        }
      } catch (e) {
        if (_log.isInternal) {
          _log.internal('Falling back to terminate on stream $streamId: $e');
        }
        pump?.dispose();
        call.incoming.terminate();
      }
      // The response state and the flow-control charge go with the record.
      call.dispose();
    }

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
    if (_isClosed) throw RpcClosedException('Transport');

    // The policy governs what we EMIT, not only what we accept. `_headerValue`
    // already rejects non-printable-ASCII, but that is a hardcoded rule, not
    // the configured one: without this, maxHeaders, maxHeaderValueBytes and the
    // name/path checks held inbound only, on the one transport of five that
    // does not get them from RpcChannelTransport.sendMetadata.
    _policy.validateMetadata(metadata);

    // A response goes out on the client-initiated stream; an unknown id
    // (server-push) must fail loudly rather than silently drop the metadata.
    final call = _requireIncomingStream(streamId, 'send metadata');

    try {
      final List<http2.Header> headers;
      // Read before the branches below record the stream, or every ending
      // would log as plain trailers.
      final kind = !endStream
          ? 'initial headers'
          : call.initialHeadersSent
          ? 'trailers'
          : 'trailers-only';

      if (!endStream) {
        // Initial response headers — includes :status: 200
        headers = rpcMetadataToHttp2ResponseHeaders(metadata);
        call.initialHeadersSent = true;
      } else if (!call.initialHeadersSent) {
        // Trailers-Only — first and last HEADERS frame.
        // Must include :status: 200 and content-type per gRPC spec.
        headers = rpcMetadataToHttp2TrailersOnly(metadata);
        call.initialHeadersSent = true;
      } else {
        // Trailers after initial headers + data.
        // MUST NOT include :status per HTTP/2 spec (RFC 7540 Section 8.1.2.1).
        headers = rpcMetadataToHttp2Trailers(metadata);
      }

      await _pumpFor(
        call,
      ).add(http2.HeadersStreamMessage(headers, endStream: endStream));

      if (_log.isInternal) {
        _log.internal('Metadata sent for stream $streamId ($kind)');
      }
    } catch (e) {
      _log.error('Error sending metadata for stream $streamId: $e');
      rethrow;
    }
  }

  @override
  Future<void> sendMessage(
    int streamId,
    Uint8List data, {
    bool endStream = false,
  }) async {
    if (_isClosed) throw RpcClosedException('Transport');

    final call = _requireIncomingStream(streamId, 'send message');

    try {
      assert(
        isGrpcFrame(data),
        'IRpcTransport.sendMessage expects a gRPC frame with a 5-byte prefix',
      );

      // Through the pump, so a peer that stops reading stops the handler --
      // `sendData` would enqueue regardless. See [_OutgoingPump].
      await _pumpFor(
        call,
      ).add(http2.DataStreamMessage(data, endStream: endStream));

      if (_log.isInternal) {
        _log.internal(
          'Sent ${data.length} response byte(s) for stream $streamId',
        );
      }
    } catch (e) {
      _log.error('Error sending data for stream $streamId: $e');
      rethrow;
    }
  }

  @override
  Future<void> finishSending(int streamId) async {
    if (_isClosed) return;

    final call = _calls[streamId];
    if (call == null) {
      if (_log.isInternal) {
        _log.internal(
          'Incoming stream $streamId not found, skipping finish sending',
        );
      }
      return;
    }

    try {
      // An empty DATA frame carrying END_STREAM.
      await _pumpFor(
        call,
      ).add(http2.DataStreamMessage(Uint8List(0), endStream: true));

      if (_log.isInternal) {
        _log.internal('Finished sending the response for stream $streamId');
      }
    } catch (e) {
      _log.warning('Error finishing the send for stream $streamId: $e');
    }
  }

  @override
  Stream<RpcTransportMessage> get incomingMessages => _messageController.stream;

  @override
  Stream<RpcTransportMessage> getMessagesForStream(int streamId) =>
      _fc.metered(streamId, _streams[streamId]);

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
  Future<void> close() async {
    if (_isClosed) return;

    _log.info('Closing the HTTP/2 responder transport');
    _isClosed = true;

    // A short grace period for streams still finishing.
    final totalStreams = _calls.length;
    if (totalStreams > 0) {
      if (_log.isInternal) {
        _log.internal('Waiting on $totalStreams active stream(s)');
      }
      await Future<void>.delayed(Duration(milliseconds: 50));
    }

    final calls = _calls.values.toList();
    for (final call in calls) {
      final stream = call.incoming;
      try {
        // Soft close, via the pump where one exists: it owns the sink, and it
        // also releases any handler parked on the peer's window so teardown
        // does not wait on a dead reader.
        final pump = call.pump;
        if (pump != null) {
          pump.endStreamNow();
        } else {
          stream.sendData(Uint8List(0), endStream: true);
        }
        if (_log.isInternal) {
          _log.internal('Sent END_STREAM for stream ${stream.id}');
        }
      } catch (e) {
        if (_log.isInternal) {
          _log.internal('Falling back to terminate on stream ${stream.id}: $e');
        }
        try {
          stream.terminate();
        } catch (e2) {
          _log.warning('Error terminating stream ${stream.id}: $e2');
        }
      }
    }

    // Release anything still parked on a peer window, after the soft close
    // above has had its chance to flush.
    for (final call in calls) {
      call.pump?.dispose();
      call.pump = null;
    }

    for (final call in calls) {
      await call.dispose();
    }
    _calls.clear();

    _streams.closeAll();

    // BOUNDED, then forceful -- see [kGracefulCloseTimeout], which the caller
    // transport shares. This half was a bare `await _connection.finish()`,
    // which is unbounded on a half-open path and, on a connection already dead,
    // throws from package:http2 into the ROOT ZONE -- the one failure mode a
    // server cannot absorb, since nothing above it is listening.
    try {
      await _connection.finish().timeout(kGracefulCloseTimeout);
    } catch (e) {
      _log.warning(
        'Graceful HTTP/2 shutdown did not complete ($e); terminating',
      );
      try {
        unawaited(_connection.terminate());
      } catch (e2) {
        _log.warning('Error closing the HTTP/2 connection: $e2');
      }
    }

    if (!_messageController.isClosed) {
      await _messageController.close();
    }

    _log.info('HTTP/2 responder transport closed');
  }

  @override
  bool get isClosed => _isClosed;

  @override
  Future<void> sendDirectObject(
    int streamId,
    Object object, {
    bool endStream = false,
  }) async {
    throw UnimplementedError('Unsupported: direct object sending');
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
