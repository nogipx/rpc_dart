// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';
import 'dart:convert';
import 'package:http2/http2.dart' as http2;
import 'package:rpc_dart/transport.dart';
import 'package:universal_io/io.dart';

import 'http2_flow_ledger.dart';
import 'http2_header_block_guard.dart';
import 'raw_socket_pipe.dart';
import 'rpc_http2_common.dart';

part 'rpc_http2_caller_transport_dial.dart';
part 'rpc_http2_caller_transport_flow.dart';
part 'rpc_http2_caller_transport_inbound.dart';
part 'rpc_http2_caller_transport_lifecycle.dart';
part 'rpc_http2_caller_transport_stream.dart';

/// Whether the peer has told us the connection is going away, and whether its
/// socket has ended.
///
/// A mutable holder rather than a field because the connection is built by a
/// static factory closure BEFORE the transport instance exists.
class _DrainSignal {
  bool goawayReceived = false;

  /// How many connections the factory has built; the guard counts them.
  int built = 0;

  /// Called with a connection's number when its socket ends. Set by the
  /// transport.
  void Function(int connection)? onSocketEnded;
}

/// Client-side HTTP/2 transport: one [IRpcTransport] over one connection,
/// multiplexing outgoing RPC calls on the gRPC-compatible wire format.
///
/// When the connection is lost the transport closes, failing what was in
/// flight with UNAVAILABLE. For reconnects, give `RpcClientConnection` a
/// factory that calls [connect] or [secureConnect].
class RpcHttp2CallerTransport extends IRpcTransport {
  @override
  bool get isClient => true;

  /// Completes when the peer's first SETTINGS frame has arrived, the point at
  /// which it is known to speak HTTP/2; fails if the connection ends first.
  /// Until then [health] reads degraded, and `RpcClientConnection` does not
  /// report Online.
  @override
  Future<void> get ready => _ready.future;
  final Completer<void> _ready = Completer<void>();

  /// See [IRpcTransport.lastIssuedStreamId]. `_nextStreamId` is the id the NEXT
  /// call will get, so the last issued one is two behind it — and -1 before
  /// any call, which is exactly "nothing issued yet".
  @override
  int get lastIssuedStreamId => _nextStreamId - 2;

  @override
  void resumeStreamIdsAfter(int streamId) {
    // Client ids are odd; a wrong-parity watermark rounds UP so the sequence
    // stays odd. Forward only, so a stale watermark cannot rewind live ids.
    final aligned = streamId.isOdd ? streamId : streamId + 1;
    if (aligned + 2 > _nextStreamId) _nextStreamId = aligned + 2;
  }

  @override
  RpcSecurityPolicy get securityPolicy => _policy;

  final http2.ClientTransportConnection _connection;

  final BufferedBroadcastController<RpcTransportMessage> _messageController =
      BufferedBroadcastController<RpcTransportMessage>(
        sizeOf: (m) => m.bufferedBytes,
      );

  /// Per-stream dedicated controllers for [getMessagesForStream].
  ///
  /// HTTP/2 already demultiplexes by stream natively, so routing each message
  /// straight to its own stream avoids re-filtering the shared broadcast once
  /// per active stream per message. The broadcast is still fed for global
  /// consumers, and keeps the [RpcHttp2StreamError] envelope semantics.
  final RpcStreamRouter _streams = RpcStreamRouter();

  /// Next outgoing stream id. The client side of HTTP/2 uses ODD ids.
  int _nextStreamId = 1;

  /// Every stream id this side holds state for; see [_CallerStream].
  final Map<int, _CallerStream> _calls = {};

  final _CallerTally _tally = _CallerTally();

  /// The record for [streamId], created unreserved if there is none.
  _CallerStream _callFor(int streamId) =>
      _calls[streamId] ??= _CallerStream(_tally);

  /// Drops [call]'s record once nothing is left in it.
  void _dropIfSpent(int streamId, _CallerStream call) {
    if (call.isSpent && identical(_calls[streamId], call)) {
      _calls.remove(streamId);
    }
  }

  /// How many calls [test] holds for.
  int _count(bool Function(_CallerStream call) test) =>
      _calls.values.where(test).length;

  /// HTTP/2 streams opened and not yet ended or reset.
  int get _activeCount => _count((call) => call.h2 != null);

  RpcHttp2OutgoingPump _pumpFor(
    _CallerStream call,
    http2.TransportStream stream,
  ) => call.pump ??= RpcHttp2OutgoingPump(stream);

  /// Streams we aborted ourselves via [resetStream].
  ///
  /// http2 reports the abort back to us as a stream error; without this we
  /// would hand a consumer that deliberately cancelled an RpcHttp2StreamError
  /// describing its own cancellation. Insertion-ordered and bounded so it
  /// cannot grow without limit on a long-lived connection.
  final Set<int> _resetStreams = {};
  static const int _maxRememberedResetStreams = 1024;

  final String _host;

  /// `http` or `https`.
  final String _scheme;

  final int _port;

  /// `:authority` for every request: the port kept unless it is the scheme's
  /// default (RFC 9113 §8.3.1), as a virtual host or a routing proxy reads it.
  late final String _authority =
      (_scheme == 'https' && _port == 443) || (_scheme == 'http' && _port == 80)
      ? _authorityHost(_host)
      : '${_authorityHost(_host)}:$_port';

  /// [host] as it appears in an authority: an IPv6 literal in brackets.
  static String _authorityHost(String host) =>
      host.contains(':') && !host.startsWith('[') ? '[$host]' : host;

  /// Set ONLY by [close]; permanent.
  bool _isClosed = false;

  /// The connection ended under this transport (its socket closed, or
  /// keepalive found the path dead), so [close] must not write a GOAWAY to it.
  bool _connectionGone = false;

  /// How often to PING an otherwise idle connection, and the ONLY way this
  /// transport detects a HALF-OPEN path.
  ///
  /// A NAT box, load balancer or mobile network that silently stops forwarding
  /// sends no FIN and no RST, so the socket still looks fine to both ends.
  /// Without a ping a call on that path hangs to its own deadline while
  /// `health()` still reports the transport ready — and that second half is
  /// what matters operationally: a supervisor polling health to decide whether
  /// to reconnect sees green and never reconnects.
  ///
  /// Null (OFF) by default. The interval is a deployment question: too short
  /// wakes radios and wastes battery, too long leaves dead connections
  /// resident. This is the client half of `GRPC_ARG_KEEPALIVE_TIME_MS`.
  final Duration? _pingInterval;

  /// How long to wait for the PING ACK before declaring the path dead.
  /// Defaults to [_pingInterval].
  final Duration? _pingTimeout;

  /// Keepalive timer for the connection.
  Timer? _keepalive;

  /// Refuses work on a closed transport.
  ///
  /// UNAVAILABLE when the connection went away under it, as for every other
  /// dead peer; FAILED_PRECONDITION only when this side closed it.
  void _ensureUsable() {
    if (!_isClosed) return;
    if (_connectionGone) throw RpcClosedException.byPeer('Transport');
    throw RpcClosedException('Transport');
  }

  final LogScope _log;

  final RpcSecurityPolicy _policy;

  RpcHttp2CallerTransport._({
    required http2.ClientTransportConnection connection,
    required String host,
    required int port,
    required String scheme,
    required RpcSecurityPolicy policy,
    LogScope? logger,
    Duration? pingInterval,
    Duration? pingTimeout,
    _DrainSignal? drainSignal,
  }) : _connection = connection,
       _host = host,
       _port = port,
       _scheme = scheme,
       _log = logger?.child('Http2ClientTransport') ?? LogScope.noop,
       _policy = policy,
       _pingInterval = pingInterval,
       _pingTimeout = pingTimeout,
       _drainSignal = drainSignal ?? _DrainSignal() {
    _connectionNumber = _drainSignal.built;
    _drainSignal.onSocketEnded = _connectionLost;
    _armReady();
    _startKeepalive();
  }

  /// Which of the factory's connections [_connection] is; see [_DrainSignal].
  int _connectionNumber = 0;

  /// Set once the peer sends GOAWAY on the current connection.
  ///
  /// `ClientTransportConnection.isOpen` is
  /// `!isFinishing && !isTerminated && canOpenStream`, so on its own it cannot
  /// tell a DRAINING peer from one merely at MAX_CONCURRENT_STREAMS — and the
  /// two need opposite responses: reconnect elsewhere versus wait for a slot.
  /// The header-block guard already parses frame headers on this connection's
  /// incoming bytes, so it reports GOAWAY (frame type 0x7) here.
  final _DrainSignal _drainSignal;

  /// Connects over TLS (h2), advertising ALPN `h2`.
  ///
  /// [proxyUri] — optional HTTP CONNECT proxy, e.g. `Uri.parse('http://proxy:3128')`.
  /// Proxy auth is taken from the URI's userinfo (`http://user:pass@proxy:3128`).
  static Future<RpcHttp2CallerTransport> secureConnect({
    required String host,
    int port = 443,
    Uri? proxyUri,
    LogScope? logger,
    RpcSecurityPolicy policy = const RpcSecurityPolicy(),
    Duration proxyHandshakeTimeout = _proxyHandshakeTimeout,
    Duration? connectTimeout = _connectTimeout,
    Duration? pingInterval,
    Duration? pingTimeout,
  }) => _dial(
    secure: true,
    host: host,
    port: port,
    proxyUri: proxyUri,
    logger: logger,
    policy: policy,
    proxyHandshakeTimeout: proxyHandshakeTimeout,
    connectTimeout: connectTimeout,
    pingInterval: pingInterval,
    pingTimeout: pingTimeout,
  );

  /// Wraps an ALREADY-ESTABLISHED socket.
  ///
  /// Use this when you need full control over the underlying connection — for
  /// example a TLS [SecureSocket] with custom certificate validation /
  /// pinning, or a socket obtained through a custom tunnel. The caller owns the
  /// socket lifecycle.
  ///
  /// [scheme] should be `https` for TLS sockets and `http` otherwise.
  factory RpcHttp2CallerTransport.viaSocket(
    Socket socket, {
    required String host,
    required int port,
    String scheme = 'https',
    LogScope? logger,
    RpcSecurityPolicy policy = const RpcSecurityPolicy(),
    Duration? pingInterval,
    Duration? pingTimeout,
  }) {
    final drainSignal = _DrainSignal();
    final connection = _guardedConnection(
      incoming: socket,
      outgoing: socket,
      destroy: socket.destroy,
      policy: policy,
      settingsTimeout: _connectTimeout,
      logger: logger,
      drainSignal: drainSignal,
    );
    return RpcHttp2CallerTransport._(
      connection: connection,
      host: host,
      port: port,
      scheme: scheme,
      policy: policy,
      logger: logger,
      pingInterval: pingInterval,
      pingTimeout: pingTimeout,
      drainSignal: drainSignal,
    );
  }

  /// Connects in plaintext (h2c).
  ///
  /// [proxyUri] — optional HTTP CONNECT proxy, e.g. `Uri.parse('http://proxy:3128')`.
  /// Proxy auth is taken from the URI's userinfo (`http://user:pass@proxy:3128`).
  static Future<RpcHttp2CallerTransport> connect({
    required String host,
    int port = 80,
    Uri? proxyUri,
    LogScope? logger,
    RpcSecurityPolicy policy = const RpcSecurityPolicy(),
    Duration proxyHandshakeTimeout = _proxyHandshakeTimeout,
    Duration? connectTimeout = _connectTimeout,
    Duration? pingInterval,
    Duration? pingTimeout,
  }) => _dial(
    secure: false,
    host: host,
    port: port,
    proxyUri: proxyUri,
    logger: logger,
    policy: policy,
    proxyHandshakeTimeout: proxyHandshakeTimeout,
    connectTimeout: connectTimeout,
    pingInterval: pingInterval,
    pingTimeout: pingTimeout,
  );

  /// Opens the connection for [connect] (h2c) and [secureConnect] (h2 over
  /// TLS, ALPN `h2` required), directly or through [proxyUri].
  static Future<RpcHttp2CallerTransport> _dial({
    required bool secure,
    required String host,
    required int port,
    required Uri? proxyUri,
    required LogScope? logger,
    required RpcSecurityPolicy policy,
    required Duration proxyHandshakeTimeout,
    required Duration? connectTimeout,
    required Duration? pingInterval,
    required Duration? pingTimeout,
  }) async {
    if (logger?.isInternal ?? false) {
      logger?.internal(
        'Opening ${secure ? 'a secure' : 'an'} HTTP/2 connection to '
        '$host:$port',
      );
    }

    final drainSignal = _DrainSignal();

    Future<http2.ClientTransportConnection> open() async {
      if (proxyUri != null) {
        return _connectH2ViaProxy(
          proxyUri: proxyUri,
          targetHost: host,
          targetPort: port,
          secure: secure,
          handshakeTimeout: proxyHandshakeTimeout,
          connectTimeout: connectTimeout,
          policy: policy,
          logger: logger,
          drainSignal: drainSignal,
        );
      }
      // `timeout:` rather than an outer `.timeout()`: dart:io abandons the
      // attempt and releases the socket, where wrapping the future would leave
      // the connect running with nobody to close what it eventually produces.
      // Under TLS it covers the handshake too.
      final Socket socket = secure
          ? await SecureSocket.connect(
              host,
              port,
              supportedProtocols: ['h2'],
              timeout: connectTimeout,
            )
          : await Socket.connect(host, port, timeout: connectTimeout);
      // See disableNagle: the proxy path does the same.
      disableNagle(
        socket,
        logger: logger,
        what: '${secure ? 'h2' : 'h2c'} socket to $host:$port',
      );
      if (socket is SecureSocket) _requireH2(socket, '$host:$port');
      return _guardedConnection(
        incoming: socket,
        outgoing: socket,
        destroy: socket.destroy,
        policy: policy,
        settingsTimeout: connectTimeout,
        logger: logger,
        drainSignal: drainSignal,
      );
    }

    final connection = await _asStatus(open);
    logger?.internal('HTTP/2 connection established');

    return RpcHttp2CallerTransport._(
      connection: connection,
      host: host,
      port: port,
      scheme: secure ? 'https' : 'http',
      policy: policy,
      logger: logger,
      pingInterval: pingInterval,
      pingTimeout: pingTimeout,
      drainSignal: drainSignal,
    );
  }

  /// How long a proxy has to answer CONNECT before the attempt is abandoned.
  ///
  /// Unbounded, this hangs an application at STARTUP: `connect()` is what it
  /// awaits, and a proxy that accepts the TCP connection and then says nothing
  /// leaves that future pending forever.
  static const Duration _proxyHandshakeTimeout = Duration(seconds: 30);

  /// How long the SOCKET may take to come up, TLS handshake included.
  ///
  /// The sibling above bounds a proxy's CONNECT response and nothing else. An
  /// address whose SYN is DROPPED rather than refused would otherwise leave
  /// `connect()` pending for the OS default, which is around 75 s and can be
  /// longer, and `connect()` is what an application awaits at startup. Pass
  /// null to wait on the OS.
  ///
  /// It also bounds the wait for the peer's first SETTINGS, after `connect()`
  /// has returned; see `_guardedConnection`.
  static const Duration _connectTimeout = Duration(seconds: 30);

  /// Opens a connection for [connect] and [secureConnect], failing with a
  /// status as the http and websocket callers do: an
  /// [RpcException] or an [Error] as it is, any other [Exception] as
  /// UNAVAILABLE, so a `shouldReconnect` has one type to branch on.
  static Future<http2.ClientTransportConnection> _asStatus(
    Future<http2.ClientTransportConnection> Function() open,
  ) async {
    try {
      return await open();
    } catch (e, st) {
      if (e is RpcException || e is! Exception) rethrow;
      Error.throwWithStackTrace(
        RpcStatusException(RpcStatus.unavailable, 'HTTP/2 connect failed: $e'),
        st,
      );
    }
  }

  @override
  int createStream() {
    _ensureUsable();

    // Same ceiling, same message and same failure mode as
    // RpcChannelTransport.createStream(). Without it `maxActiveStreams` was
    // inert on this transport, silently: a client configured with 5 opened 500
    // concurrent streams -- 500 HTTP/2 streams, 500 subscriptions, 500 stream
    // controllers -- with nothing refused and no error anywhere. The same
    // configuration threw on the 6th call over every other transport.
    //
    // HTTP/2's own SETTINGS_MAX_CONCURRENT_STREAMS does not cover for it
    // either, because RpcHttp2Server never derives that from the policy.
    if (_tally.reserved >= _policy.maxActiveStreams) {
      // RESOURCE_EXHAUSTED, matching the channel transport: a transient limit
      // the caller can back off from, not a mistake it made.
      throw RpcStatusException.atCapacity(
        'Too many active streams: ${_tally.reserved} '
        '(max: ${_policy.maxActiveStreams})',
      );
    }

    final streamId = _nextStreamId;
    _nextStreamId += 2; // Client ids are odd: 1, 3, 5, ...
    _callFor(streamId).reserved = true;

    if (_log.isInternal) {
      _log.internal('Created stream $streamId');
    }
    return streamId;
  }

  @override
  bool releaseStreamId(int streamId) {
    if (_isClosed) return false;

    if (_log.isInternal) {
      _log.internal('Releasing stream $streamId');
    }

    // Release must NOT write to the stream. By the time the pipeline releases
    // an id the request direction is already finished -- every call ends with
    // END_STREAM -- so an empty `sendData(endStream: true)` here is a DATA
    // frame on a half-closed (local) stream. package:http2 treats that as a
    // CONNECTION error and terminates the connection, taking every other call
    // on it down, and the throw is asynchronous so the try/catch below never
    // sees it.
    //
    // A stream that has NOT been half-closed is one the caller abandoned
    // mid-request; RST_STREAM is the legal way to drop that.
    final call = _calls.remove(streamId);
    if (call == null) return true;
    final stream = call.h2;
    if (stream != null && !call.halfClosedLocal) {
      try {
        stream.terminate();
        if (_log.isInternal) {
          _log.internal('RST_STREAM on unfinished stream $streamId');
        }
      } catch (e) {
        if (_log.isInternal) {
          _log.internal('Could not reset stream $streamId: $e');
        }
      }
    }

    // Releases anything parked on the server's window before the subscription
    // goes, or a caller awaiting sendMessage never unwinds once its stream is
    // gone. The peer-ended mark and the flow-control charge go with the record.
    call.dispose();

    return true;
  }

  @override
  Future<void> sendMetadata(
    int streamId,
    RpcMetadata metadata, {
    bool endStream = false,
  }) async {
    _ensureUsable();

    // See the responder's sendMetadata: the configured policy has to apply
    // outbound here too, or it is a one-directional rule on this transport
    // alone.
    _policy.validateMetadata(metadata);

    // NO methodPath means this is not an opening frame, and on HTTP/2 only an
    // opening frame can carry client metadata -- `makeRequest` OPENS a stream.
    // Core sends exactly one such frame, the cancellation notice, and only after
    // `resetStream` said it could not deliver it, which happens when the id has
    // no stream. Defaulting the path sent that notice as a request: measured, a
    // cancel after a completed call made the server see
    // `[/Svc/Echo, /Unknown/Unknown]`. The same defect the HTTP/1.1 caller fixed,
    // for the same reason -- see its sendMetadata.
    final methodPath = metadata.methodPath;
    if (methodPath == null) {
      if (_log.isInternal) {
        _log.internal(
          'No methodPath for stream $streamId; nothing to put on the wire '
          '(a cancel is an RST_STREAM, see resetStream)',
        );
      }
      return;
    }

    // An id with a stream already has its opening frame. Overwriting it would
    // strand the first stream and its subscription with nothing tracking
    // either.
    if (_calls[streamId]?.h2 != null) {
      throw RpcStatusException(
        RpcStatus.failedPrecondition,
        'HTTP/2 stream $streamId is already open; a second opening frame would '
        'strand it',
      );
    }

    if (_log.isInternal) {
      _log.internal(
        'Sending metadata for stream $streamId: $methodPath '
        '(endStream: $endStream)',
      );
    }

    final headers = rpcMetadataToHttp2RequestHeaders(
      metadata,
      method: 'POST',
      path: methodPath,
      scheme: _scheme,
      authority: _authority,
    );

    // A connection that is gone must be reported as UNAVAILABLE, never as
    // package:http2's raw StateError, which nothing above the transport can
    // classify: RpcRetryInterceptor retries UNAVAILABLE and RESOURCE_EXHAUSTED
    // and cannot act on a StateError at all. GOAWAY is the routine case, not an
    // exotic one -- every load balancer drains with it, and every gRPC server
    // with a max-connection-age sends it on a schedule.
    //
    // This makes the failure CLASSIFIABLE; it does not by itself make a retry
    // succeed on a dead connection -- that needs a new transport, which
    // RpcClientConnection builds. Both checks are here because isOpen can go
    // false between the test and the call.
    if (!_connection.isOpen) {
      // `ClientTransportConnection.isOpen` is
      //   !isFinishing && !isTerminated && canOpenStream
      // so it folds a HEALTHY connection merely at the peer's
      // MAX_CONCURRENT_STREAMS (canOpenStream == false) together with a dead
      // one. Reporting the first as "the peer closed it or sent GOAWAY;
      // reconnect" is wrong three ways: the peer is alive, it sent no GOAWAY,
      // and reconnecting drops every in-flight call instead of waiting for a
      // slot.
      //
      // canOpenStream can only be false while streams are in flight, so our own
      // active-stream count separates the cases: not-open WITH active streams
      // is saturation, not-open with none is a finishing/terminated connection.
      //
      // GOAWAY outranks that heuristic and MUST: a draining connection also has
      // streams in flight, so checking saturation first reports a shutting-down
      // connection as "healthy, wait for a slot" for the whole drain -- which
      // can last as long as the server's budget.
      if (_drainSignal.goawayReceived) {
        throw RpcStatusException(
          RpcStatus.unavailable,
          'HTTP/2 connection to $_host:$_port is draining (the peer sent '
          'GOAWAY); reconnect rather than retrying on this connection',
        );
      }
      final active = _activeCount;
      if (active > 0) {
        throw RpcStatusException.atCapacity(
          'HTTP/2 connection to $_host:$_port is at the server\'s '
          'MAX_CONCURRENT_STREAMS limit ($active in flight); '
          'the connection is healthy, so retry when one completes rather than '
          'reconnecting',
        );
      }
      throw RpcStatusException(
        RpcStatus.unavailable,
        'HTTP/2 connection to $_host:$_port is no longer active (the peer '
        'closed it or sent GOAWAY); reconnect and retry',
      );
    }
    final http2.ClientTransportStream stream;
    try {
      stream = _connection.makeRequest(headers, endStream: endStream);
    } on StateError catch (error) {
      throw RpcStatusException(
        RpcStatus.unavailable,
        'HTTP/2 connection to $_host:$_port refused a new stream: '
        '${error.message}',
      );
    }
    final call = _callFor(streamId)..h2 = stream;
    if (endStream) call.halfClosedLocal = true;

    if (_log.isInternal) {
      _log.internal('HTTP/2 stream $streamId opened (active: $_activeCount)');
    }

    _setupStreamListener(streamId, call, stream, methodPath);

    if (_log.isInternal) {
      _log.internal('Metadata sent for stream $streamId');
    }
  }

  @override
  Future<bool> resetStream(int streamId, {String? reason}) async {
    // An id with no open stream (reserved and never opened, or ended by the
    // peer) keeps its record as it is until release.
    final call = _calls[streamId];
    final stream = call?.h2;
    if (call == null || stream == null) return false;
    call.h2 = null;

    // RST_STREAM is the only legal way to abort a stream we have already
    // half-closed, which is exactly when cancellation arrives. Sending the
    // cancellation metadata frame instead throws "Open state expected (was:
    // HalfClosedLocal)" asynchronously out of the http2 stream handler.
    if (_log.isInternal) {
      _log.internal(
        'Resetting stream $streamId with RST_STREAM'
        '${reason != null ? ': $reason' : ''}',
      );
    }

    // Tear the local side down FIRST. Terminating makes http2 surface the
    // reset back to us as a stream error, and _emitStreamError would then
    // push an RpcHttp2StreamError at a consumer that deliberately cancelled --
    // reporting its own cancellation to it as a transport failure.
    if (_resetStreams.add(streamId) &&
        _resetStreams.length > _maxRememberedResetStreams) {
      _resetStreams.remove(_resetStreams.first);
    }

    // Read BEFORE the cleanup below drops it.
    final halfClosed = call.halfClosedLocal;

    // Same steps `releaseStreamId` takes, and for its stated reason: release
    // anything parked on the server's window BEFORE the subscription goes, and
    // forget the flow-control charge. The exchange is forgotten once the cancel
    // has landed; the peer-ended mark is untouched.
    call.pump?.dispose();
    call.pump = null;
    _fc.forget(streamId);

    final subscription = call.subscription;
    call.subscription = null;
    await subscription?.cancel();
    call.endExchange();
    _dropIfSpent(streamId, call);
    final controller = _streams.remove(streamId);
    if (controller != null && !controller.isClosed) {
      unawaited(controller.close());
    }

    // Same guard `releaseStreamId` uses, for the same reason one file over.
    //
    // On a stream we have already half-closed, package:http2 sends the
    // RST_STREAM itself: cancelling the incoming subscription above runs its
    // `streamQueueIn.onCancel`, which enqueues a ResetStreamMessage when the
    // state is HalfClosedLocal. That one goes through the stream's OUTGOING
    // QUEUE, in order behind our own frames. `terminate()` instead writes the
    // frame immediately, and doing both is what costs the connection: measured
    // over a 50 ms link, a consumer letting go one event before the trailer
    // took the whole connection down from the second call, and does not with
    // this guard. A stream we have NOT half-closed is one the caller abandoned
    // mid-request, where http2 sends nothing and RST_STREAM is the only signal
    // that stops the handler.
    if (!halfClosed) stream.terminate();
    return true;
  }

  @override
  Future<void> sendMessage(
    int streamId,
    Uint8List data, {
    bool endStream = false,
  }) async {
    _ensureUsable();

    final call = _calls[streamId];
    final stream = call?.h2;
    if (call == null || stream == null) {
      // The peer has ended this stream, and its status is the call's outcome:
      // a request sent after it is dropped, as on the other transports. An
      // error here reached a paused caller ahead of that status and replaced it.
      if (call?.peerEnded ?? false) {
        if (_log.isInternal) {
          _log.internal('Dropped a send on stream $streamId the peer ended');
        }
        return;
      }
      throw RpcStatusException(
        RpcStatus.failedPrecondition,
        'Stream $streamId not found. Send metadata first.',
      );
    }

    assert(
      isGrpcFrame(data),
      'IRpcTransport.sendMessage expects a gRPC frame with a 5-byte prefix',
    );

    if (call.halfClosedLocal) {
      // Already half-closed: another DATA frame is a connection error.
      _log.warning('Dropped a send on finished stream $streamId');
      return;
    }

    // Through the pump: `sendData` does not wait for the server's window, so
    // the whole request would settle in package:http2's outgoing queue. See
    // [_CallerStream.pump].
    await _pumpFor(
      call,
      stream,
    ).add(http2.DataStreamMessage(data, endStream: endStream));
    // Looked up again, because this add is the only one of three that sits
    // behind an await: a peer RST_STREAM arriving while the send was parked
    // tears the stream down and wakes the pump, and a half-close recorded
    // after that would keep a record nothing removes again.
    final after = _calls[streamId];
    if (endStream && after?.h2 != null) after!.halfClosedLocal = true;

    if (_log.isInternal) {
      _log.internal(
        'Sent ${data.length} byte(s) for stream $streamId '
        '(endStream: $endStream)',
      );
    }
  }

  @override
  Future<void> finishSending(int streamId) async {
    if (_isClosed) return;

    final call = _calls[streamId];
    final stream = call?.h2;
    if (call == null || stream == null) return;

    // Idempotent, like RpcChannelTransport.finishSending: a caller that
    // already passed `endStream: true` to sendMessage/sendMetadata has closed
    // the request direction, and a second END_STREAM would be a DATA frame on
    // a half-closed stream -- a CONNECTION error in HTTP/2.
    if (call.halfClosedLocal) {
      if (_log.isInternal) {
        _log.internal('Stream $streamId is already finished; nothing to do');
      }
      return;
    }

    // END_STREAM WITHOUT waiting on the peer's window: a half-close is a
    // signal, not payload, and it must not hang on a dead peer.
    final pump = call.pump;
    if (pump != null) {
      pump.endStreamNow();
    } else {
      stream.sendData(Uint8List(0), endStream: true);
    }
    call.halfClosedLocal = true;

    if (_log.isInternal) {
      _log.internal('Finished sending for stream $streamId');
    }
  }

  int _policyViolations = 0;

  @override
  Stream<RpcTransportMessage> get incomingMessages => _messageController.stream;

  /// Always METERED, on the first call and on a repeat.
  ///
  /// Wrapping only the freshly-created controller and handing an existing one
  /// back raw is the shape to avoid: the second consumer of a stream then never
  /// discharges its budget, so its charge only climbs and the call is refused
  /// at the window for bytes it did in fact consume. The responder sibling
  /// meters both paths.
  @override
  Stream<RpcTransportMessage> getMessagesForStream(int streamId) =>
      _fc.metered(streamId, _streams[streamId]);

  /// The un-consumed RESPONSE bound; see [_Http2CallerFlow].
  ///
  /// Charged only for a stream with a per-stream consumer, the one that
  /// discharges it.
  late final Http2FlowLedger _fc = Http2FlowLedger(
    policy: _policy,
    accountOf: (streamId) => _calls[streamId]?.flow,
    isMetered: (streamId, _) => _streams.contains(streamId),
    onOverrun: _fcFailOverrun,
  );

  @override
  Future<RpcHealthStatus> health() async {
    final details = _buildHealthDetails();

    if (_messageController.isClosed || _isClosed) {
      return RpcHealthStatus.closed(
        component: runtimeType.toString(),
        message: _connectionGone
            ? 'HTTP/2 connection to $_host:$_port was lost; transport closed'
            : 'HTTP/2 transport closed',
        details: details,
      );
    }

    if (!_ready.isCompleted) {
      // A SETTINGS that has already arrived reports on a later microtask.
      try {
        await _ready.future.timeout(Duration.zero);
      } catch (_) {
        // Not yet, or the connection ended: reported below or above.
      }
    }
    if (!_ready.isCompleted) {
      return RpcHealthStatus.degraded(
        component: runtimeType.toString(),
        message: 'HTTP/2 peer has not sent its SETTINGS yet',
        details: details,
      );
    }

    // Ask the connection, do not assume: a connection that is finishing or
    // terminated without its socket ending yet reaches no code here.
    //
    // Note this is the REPORT, not a refusal: a dead or drained connection
    // answers UNAVAILABLE from the send path and stays retryable.
    // `_ensureUsable` is NOT wired to this on purpose -- routing it here turns
    // those calls into a FAILED_PRECONDITION nobody retries.
    if (!_connection.isOpen) {
      // Not-open with streams in flight is SATURATION, not death: the
      // connection is at the peer's MAX_CONCURRENT_STREAMS and is actively
      // serving. Reporting it "down / reconnect required" would make a
      // supervisor drop a healthy connection and every call on it. Only
      // not-open with no active streams is a finishing/terminated connection.
      // See the same split in sendMetadata().
      // Draining is not capacity. See the same split in sendMetadata().
      final active = _activeCount;
      if (_drainSignal.goawayReceived) {
        return RpcHealthStatus.degraded(
          component: runtimeType.toString(),
          message:
              'HTTP/2 connection is draining (peer sent GOAWAY); '
              '$active call(s) still finishing.',
          details: details,
        );
      }
      if (active > 0) {
        return RpcHealthStatus.healthy(
          component: runtimeType.toString(),
          message:
              'HTTP/2 transport at capacity: $active streams '
              'in flight (server MAX_CONCURRENT_STREAMS reached)',
          details: details,
        );
      }
      return RpcHealthStatus.degraded(
        component: runtimeType.toString(),
        message: 'HTTP/2 connection is down',
        details: details,
      );
    }

    return RpcHealthStatus.healthy(
      component: runtimeType.toString(),
      message: 'HTTP/2 transport ready',
      details: details,
    );
  }

  @override
  Future<void> close() async {
    if (_isClosed) return;

    _log.info('Closing the HTTP/2 transport');
    _isClosed = true;
    // Stop probing before anything is torn down: a ping issued against a
    // connection this method is about to terminate would fail and re-run the
    // keepalive's own teardown path on an already-closing transport.
    _keepalive?.cancel();
    _keepalive = null;

    // Abort EVERY remaining stream at once, half-closed ones INCLUDED. close()
    // is the abort; a caller that wants calls to finish awaits them first.
    //
    // Skipping the half-closed ones means skipping every ordinary unary call,
    // since those send endStream: true with the request. Those streams stay
    // open on the wire while the lines below cancel their subscriptions and
    // close their controllers -- so no response can reach the caller -- and
    // `finish()` at the end of this method then waits for exactly them. That
    // blocks shutdown for up to the graceful budget on work whose answer has
    // already been made undeliverable; the wait cannot rescue a call, it only
    // delays close().
    //
    // RST_STREAM is legal on a half-closed stream, and is the only legal way to
    // abort after END_STREAM. The rule that suggests otherwise is about DATA,
    // not RST: never send DATA on a stream whose request direction is finished.
    final calls = _calls.values.toList();
    for (final call in calls) {
      final stream = call.h2;
      if (stream == null) continue;
      call.h2 = null;
      try {
        stream.terminate();
        if (_log.isInternal) {
          _log.internal('RST_STREAM on stream ${stream.id} during close');
        }
      } catch (e) {
        _log.warning('Error closing stream ${stream.id}: $e');
      }
    }

    final subscriptionsToCancel = <StreamSubscription<void>>[];
    for (final call in calls) {
      final subscription = call.subscription;
      call.subscription = null;
      if (subscription != null) subscriptionsToCancel.add(subscription);
    }
    for (final subscription in subscriptionsToCancel) {
      try {
        await subscription.cancel();
      } catch (e) {
        _log.warning('Error cancelling a subscription: $e');
      }
    }
    // Release every producer parked on a server window before the streams go.
    // Every subscription is already cancelled. Nothing outlives a closed
    // transport, the flow-control charge included.
    for (final call in _calls.values) {
      unawaited(call.dispose());
      call.flow.forget();
    }
    _calls.clear();

    _streams.closeAll();

    if (!_messageController.isClosed) {
      try {
        await _messageController.close();
      } catch (e) {
        _log.warning('Error closing the message controller: $e');
      }
    }

    // A connection that is already gone was terminated by [_connectionLost];
    // a GOAWAY written to it throws from package:http2 into the root zone.
    if (_connectionGone) {
      _log.info('HTTP/2 transport closed');
      return;
    }

    // BOUNDED, then forceful -- see [kGracefulCloseTimeout], which the
    // responder transport shares.
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

    _log.info('HTTP/2 transport closed');
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
