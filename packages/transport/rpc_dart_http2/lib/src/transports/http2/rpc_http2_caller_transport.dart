// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';
import 'dart:convert';
import 'package:http2/http2.dart' as http2;
import 'package:meta/meta.dart';
import 'package:rpc_dart/rpc_dart.dart';
import 'package:universal_io/io.dart';

import 'http2_header_block_guard.dart';
import 'raw_socket_pipe.dart';
import 'rpc_http2_common.dart';

part 'rpc_http2_caller_transport_dial.dart';
part 'rpc_http2_caller_transport_flow.dart';
part 'rpc_http2_caller_transport_inbound.dart';
part 'rpc_http2_caller_transport_lifecycle.dart';

/// Whether the peer has told us this connection is going away, and which
/// connection's socket has ended.
///
/// A mutable holder rather than a field because the connection is built by a
/// static factory closure BEFORE the transport instance exists, and the same
/// closure is re-run by [RpcHttp2CallerTransport.reconnect]. One holder per
/// transport, shared with every connection it builds, reset on attach.
class _DrainSignal {
  bool goawayReceived = false;

  /// How many connections the factory has built. The one just built is the
  /// one being attached, so its number is this count.
  int built = 0;

  /// Called with a connection's number when its socket ends. Set by the
  /// transport; a number lets it ignore a connection it has already replaced.
  void Function(int connection)? onSocketEnded;
}

/// Client-side HTTP/2 transport: one [IRpcTransport] over one connection,
/// multiplexing outgoing RPC calls on the gRPC-compatible wire format.
///
/// Declares [IRpcSecurityPolicyAware] because the endpoint layers find the
/// policy with an `is` check: a transport that does not declare it silently
/// gets `const RpcSecurityPolicy()` instead of the configured one.
class RpcHttp2CallerTransport
    implements
        IRpcReconnectableTransport,
        IRpcStreamReset,
        IRpcSecurityPolicyAware,
        IRpcConnectionLossReporting,
        IRpcTransportReadiness {
  @override
  bool get isClient => true;

  /// Completes when the peer's first SETTINGS frame has arrived on the current
  /// connection, the point at which it is known to speak HTTP/2; fails if that
  /// connection ends first. Until then [health] reads degraded, and
  /// `RpcClientConnection` does not report Online.
  @override
  Future<void> get ready => _ready.future;
  Completer<void> _ready = Completer<void>();

  /// See [IRpcStreamIdSequence]. `_nextStreamId` is the id the NEXT call will
  /// get, so the last issued one is two behind it — and -1 before any call,
  /// which is exactly "nothing issued yet".
  ///
  /// This transport fixes its own `reconnect()` by simply not resetting the
  /// counter; the capability is for `RpcClientConnection`, which does not
  /// reconnect a transport but builds a NEW one and so cannot rely on that.
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

  http2.ClientTransportConnection _connection;

  /// Rebuilds the connection on [reconnect], or null when it cannot be rebuilt.
  ///
  /// **Null, not a closure that throws.** `viaSocket` used to pass
  /// `() => throw ...('does not support reconnect')`, so the only way to learn
  /// a fact fixed at CONSTRUCTION was to call it — and [reconnect] calls it
  /// last, after cancelling every subscription, disposing every pump and
  /// clearing six per-stream maps. A working connection was destroyed to
  /// discover it could not be replaced.
  final Future<http2.ClientTransportConnection> Function()? _connectionFactory;

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

  /// Live HTTP/2 streams.
  final Map<int, http2.ClientTransportStream> _activeStreams = {};

  /// Backpressured writers, one per request stream.
  ///
  /// `sendData` enqueues regardless of the server's window, so without a pump a
  /// server whose handler stops consuming does not slow this client down at
  /// all: the whole request is pulled into package:http2's outgoing queue, in
  /// this process's memory, while a fraction of it is on the wire.
  ///
  /// Unlike the responder there is no header/data ordering to preserve here:
  /// HEADERS go out with `makeRequest`, so this sink only ever carries DATA.
  final Map<int, RpcHttp2OutgoingPump> _outgoingPumps = {};

  RpcHttp2OutgoingPump _pumpFor(int streamId, http2.TransportStream stream) =>
      _outgoingPumps[streamId] ??= RpcHttp2OutgoingPump(stream);

  final Map<int, StreamSubscription<void>> _streamSubscriptions = {};

  /// Per-stream frame parsers, which carry the state for a fragmented message.
  final Map<int, RpcMessageParser> _streamParsers = {};

  /// Streams this side has already half-closed by sending END_STREAM.
  ///
  /// HTTP/2 forbids a DATA frame on a stream that is half-closed (local), and
  /// package:http2 answers that violation by tearing down the whole CONNECTION
  /// -- not just the stream. Every path that ends the request direction records
  /// the id here so no later path sends a second one.
  final Set<int> _halfClosedLocal = {};

  /// Streams whose response carried a gRPC status (trailers, or a
  /// Trailers-Only response).
  ///
  /// package:http2 completes a stream's `incomingMessages` NORMALLY when the
  /// connection goes away mid-response, so `onDone` alone cannot tell a
  /// finished call from a truncated one. Without this a server stream cut off
  /// by a dead peer reaches the consumer as a clean end — partial data reported
  /// as complete, with no error anywhere.
  final Set<int> _statusReceived = {};

  /// Ids handed out by [createStream] that have not been retired yet.
  ///
  /// [_activeStreams] only gains an id once [sendMetadata] opens the HTTP/2
  /// stream, so counting it cannot bound stream CREATION: a burst of
  /// createStream() calls all pass before the first reaches sendMetadata. This
  /// is what [createStream] counts, and every path that retires an id drops it
  /// here too.
  final Set<int> _reservedStreams = {};

  /// Tracks streams where initial response headers have been received.
  /// Used to distinguish trailers from initial response headers on incoming.
  final Set<int> _initialHeadersReceived = {};

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

  /// No live connection, but recovery is expected.
  ///
  /// Distinct from [_isClosed], which is terminal. Conflate them and a failed
  /// [reconnect] becomes permanent: [health] reads the flag as "reconnect
  /// required" and reports DEGRADED, while the send paths and [reconnect]'s own
  /// post-factory re-check read it as "the caller closed us" — so the transport
  /// tells you to reconnect and then refuses every attempt.
  bool _disconnected = false;

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

  /// Keepalive timer for the CURRENT connection. Reconnect replaces the
  /// connection, so it must also replace this.
  Timer? _keepalive;

  /// Refuses work the transport genuinely cannot do, naming which state it is
  /// in, because the two are not recoverable in the same way.
  void _ensureUsable() {
    if (_isClosed) throw RpcClosedException('Transport');
    if (_disconnected) {
      // Same type as the websocket sibling, deliberately, and the type now
      // carries the split both machines used to get wrong: UNAVAILABLE while a
      // reconnect is IN FLIGHT, FAILED_PRECONDITION once it has failed. This
      // transport answered 14 in the first case only by accident — it discards
      // the connection before the await, so the send path threw before any
      // guard ran — and 9 from here once the flag was set.
      // Read off the SINGLE-FLIGHT future, not a second flag: that field is
      // already "an attempt is in flight", it is cleared by one `whenComplete`
      // rather than at each of reconnect()'s exits, and a second copy would be
      // one more thing to leave set after a failure.
      throw RpcNoConnectionException(
        'Transport',
        reconnecting: _reconnecting != null,
      );
    }
  }

  final LogScope? _logger;

  final RpcSecurityPolicy _policy;

  RpcHttp2CallerTransport._({
    required http2.ClientTransportConnection connection,
    required Future<http2.ClientTransportConnection> Function()?
    connectionFactory,
    required String host,
    required int port,
    required String scheme,
    required RpcSecurityPolicy policy,
    LogScope? logger,
    Duration? pingInterval,
    Duration? pingTimeout,
    _DrainSignal? drainSignal,
  }) : _connection = connection,
       _connectionFactory = connectionFactory,
       _host = host,
       _port = port,
       _scheme = scheme,
       _logger = logger?.child('Http2ClientTransport'),
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

  /// The last connection whose loss was reported, so it is reported once.
  int _lostConnection = -1;

  /// One event per connection lost while this transport stays open for
  /// [reconnect].
  @override
  Stream<Object?> get connectionLost => _lostCtl.stream;
  final StreamController<Object?> _lostCtl =
      StreamController<Object?>.broadcast();

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
  }) async {
    if (logger?.isInternal ?? false) {
      logger?.internal('Opening a secure HTTP/2 connection to $host:$port');
    }

    final drainSignal = _DrainSignal();

    Future<http2.ClientTransportConnection> createConnection() async {
      if (proxyUri != null) {
        return _connectH2ViaProxy(
          proxyUri: proxyUri,
          targetHost: host,
          targetPort: port,
          secure: true,
          handshakeTimeout: proxyHandshakeTimeout,
          connectTimeout: connectTimeout,
          policy: policy,
          logger: logger,
          drainSignal: drainSignal,
        );
      }
      // See the h2c path: `timeout:` releases the attempt, an outer wrapper does
      // not. This one also covers the TLS handshake.
      final socket = await SecureSocket.connect(
        host,
        port,
        supportedProtocols: ['h2'],
        timeout: connectTimeout,
      );
      // The proxy path below has always done this; the direct path had not, so
      // the same class produced differently configured sockets. See
      // disableNagle.
      disableNagle(socket, logger: logger, what: 'h2 socket to $host:$port');
      _requireH2(socket, '$host:$port');
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

    final connection = await createConnection();
    logger?.internal('HTTP/2 connection established');

    return RpcHttp2CallerTransport._(
      connection: connection,
      connectionFactory: createConnection,
      host: host,
      port: port,
      scheme: 'https',
      policy: policy,
      logger: logger,
      pingInterval: pingInterval,
      pingTimeout: pingTimeout,
      drainSignal: drainSignal,
    );
  }

  /// Wraps an ALREADY-ESTABLISHED socket.
  ///
  /// Use this when you need full control over the underlying connection — for
  /// example a TLS [SecureSocket] with custom certificate validation /
  /// pinning, or a socket obtained through a custom tunnel. The caller owns the
  /// socket lifecycle; [reconnect] is not supported (the factory cannot rebuild
  /// the original socket), so a closed transport stays closed.
  ///
  /// [scheme] should be `https` for TLS sockets and `http` otherwise.
  ///
  /// [connectionFactory] is for TESTS that need a reconnect attempt to FAIL
  /// over a connection that stays healthy — the two are different events and
  /// `reconnect` answers them differently. Production callers leave it null,
  /// which is what makes the refusal free of side effects.
  factory RpcHttp2CallerTransport.viaSocket(
    Socket socket, {
    required String host,
    required int port,
    String scheme = 'https',
    LogScope? logger,
    RpcSecurityPolicy policy = const RpcSecurityPolicy(),
    Duration? pingInterval,
    Duration? pingTimeout,
    @visibleForTesting
    Future<http2.ClientTransportConnection> Function()? connectionFactory,
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
      // NULL, not a throwing closure: the originating socket cannot be
      // recreated, and that is known here rather than discovered by reconnect()
      // after it has already torn the live connection down.
      connectionFactory: connectionFactory,
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
  }) async {
    if (logger?.isInternal ?? false) {
      logger?.internal('Opening an HTTP/2 connection to $host:$port');
    }

    final drainSignal = _DrainSignal();

    Future<http2.ClientTransportConnection> createConnection() async {
      if (proxyUri != null) {
        return _connectH2ViaProxy(
          proxyUri: proxyUri,
          targetHost: host,
          targetPort: port,
          secure: false,
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
      final socket = await Socket.connect(host, port, timeout: connectTimeout);
      // See disableNagle: same reason as the h2c/TLS and proxy paths.
      disableNagle(socket, logger: logger, what: 'h2c socket to $host:$port');
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

    final connection = await createConnection();
    logger?.internal('HTTP/2 connection established');

    return RpcHttp2CallerTransport._(
      connection: connection,
      connectionFactory: createConnection,
      host: host,
      port: port,
      scheme: 'http',
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
  /// The sibling above bounds a proxy's CONNECT response and nothing else, so an
  /// address whose SYN is DROPPED rather than refused left `connect()` pending
  /// with no bound of ours at all — the OS default, which is around 75 s and can
  /// be longer. Measured: a refused port fails in 10 ms, a black-holed one was
  /// still pending at 12 s.
  ///
  /// This is the bound the proxy field's own doc describes and did not provide:
  /// `connect()` is what an application awaits at startup. Pass null for the old
  /// behaviour of waiting on the OS.
  ///
  /// It also bounds the wait for the peer's first SETTINGS, after `connect()`
  /// has returned; see `_guardedConnection`.
  static const Duration _connectTimeout = Duration(seconds: 30);

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
    if (_reservedStreams.length >= _policy.maxActiveStreams) {
      // RESOURCE_EXHAUSTED, matching the channel transport: a transient limit
      // the caller can back off from, not a mistake it made.
      throw RpcStatusException.atCapacity(
        'Too many active streams: ${_reservedStreams.length} '
        '(max: ${_policy.maxActiveStreams})',
      );
    }

    final streamId = _nextStreamId;
    _nextStreamId += 2; // Client ids are odd: 1, 3, 5, ...
    _reservedStreams.add(streamId);

    if (_logger?.isInternal ?? false) {
      _logger?.internal('Created stream $streamId');
    }
    return streamId;
  }

  @override
  bool releaseStreamId(int streamId) {
    if (_isClosed) return false;

    if (_logger?.isInternal ?? false) {
      _logger?.internal('Releasing stream $streamId');
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
    final stream = _activeStreams.remove(streamId);
    if (stream != null && !_halfClosedLocal.contains(streamId)) {
      try {
        stream.terminate();
        if (_logger?.isInternal ?? false) {
          _logger?.internal('RST_STREAM on unfinished stream $streamId');
        }
      } catch (e) {
        if (_logger?.isInternal ?? false) {
          _logger?.internal('Could not reset stream $streamId: $e');
        }
      }
    }

    // Release anything parked on the server's window first, or a caller
    // awaiting sendMessage never unwinds once its stream is gone.
    _outgoingPumps.remove(streamId)?.dispose();

    final subscription = _streamSubscriptions.remove(streamId);
    subscription?.cancel();

    _streamParsers.remove(streamId);
    _initialHeadersReceived.remove(streamId);
    _halfClosedLocal.remove(streamId);
    _reservedStreams.remove(streamId);
    _statusReceived.remove(streamId);
    _fcForget(streamId);

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
      if (_logger?.isInternal ?? false) {
        _logger?.internal(
          'No methodPath for stream $streamId; nothing to put on the wire '
          '(a cancel is an RST_STREAM, see resetStream)',
        );
      }
      return;
    }

    // An id with a stream already has its opening frame. Overwriting
    // `_activeStreams[streamId]` stranded the first stream and its subscription
    // with nothing tracking either.
    if (_activeStreams.containsKey(streamId)) {
      throw RpcStatusException(
        RpcStatus.failedPrecondition,
        'HTTP/2 stream $streamId is already open; a second opening frame would '
        'strand it',
      );
    }

    if (_logger?.isInternal ?? false) {
      _logger?.internal(
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
    // succeed on a dead connection -- that needs reconnect(). Both checks are
    // here because isOpen can go false between the test and the call.
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
      if (_activeStreams.isNotEmpty) {
        throw RpcStatusException.atCapacity(
          'HTTP/2 connection to $_host:$_port is at the server\'s '
          'MAX_CONCURRENT_STREAMS limit (${_activeStreams.length} in flight); '
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
    _activeStreams[streamId] = stream;
    if (endStream) _halfClosedLocal.add(streamId);

    if (_logger?.isInternal ?? false) {
      _logger?.internal(
        'HTTP/2 stream $streamId opened (active: ${_activeStreams.length})',
      );
    }

    _setupStreamListener(streamId, stream, methodPath);

    if (_logger?.isInternal ?? false) {
      _logger?.internal('Metadata sent for stream $streamId');
    }
  }

  @override
  Future<bool> resetStream(int streamId, {String? reason}) async {
    final stream = _activeStreams.remove(streamId);
    if (stream == null) return false;

    // RST_STREAM is the only legal way to abort a stream we have already
    // half-closed, which is exactly when cancellation arrives. Sending the
    // cancellation metadata frame instead throws "Open state expected (was:
    // HalfClosedLocal)" asynchronously out of the http2 stream handler.
    if (_logger?.isInternal ?? false) {
      _logger?.internal(
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
    final halfClosed = _halfClosedLocal.contains(streamId);

    // Same two steps `releaseStreamId` takes, and for its stated reason: release
    // anything parked on the server's window BEFORE the subscription goes, and
    // forget the flow-control charge. This path had neither, so cancelling a
    // call left its outgoing pump behind -- measured `pumps 1 -> 1` here against
    // `1 -> 0` for `releaseStreamId` on the same stream.
    _outgoingPumps.remove(streamId)?.dispose();
    _fcForget(streamId);

    await _streamSubscriptions.remove(streamId)?.cancel();
    _streamParsers.remove(streamId);
    _initialHeadersReceived.remove(streamId);
    _halfClosedLocal.remove(streamId);
    _reservedStreams.remove(streamId);
    _statusReceived.remove(streamId);
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

    final stream = _activeStreams[streamId];
    if (stream == null) {
      throw RpcStatusException(
        RpcStatus.failedPrecondition,
        'Stream $streamId not found. Send metadata first.',
      );
    }

    assert(
      isGrpcFrame(data),
      'IRpcTransport.sendMessage expects a gRPC frame with a 5-byte prefix',
    );

    if (_halfClosedLocal.contains(streamId)) {
      // Already half-closed: another DATA frame is a connection error.
      _logger?.warning('Dropped a send on finished stream $streamId');
      return;
    }

    // Through the pump: `sendData` does not wait for the server's window, so
    // the whole request would settle in package:http2's outgoing queue. See
    // [_outgoingPumps].
    await _pumpFor(
      streamId,
      stream,
    ).add(http2.DataStreamMessage(data, endStream: endStream));
    // `containsKey`, because this add is the only one of three that sits behind
    // an await: a peer RST_STREAM arriving while the send was parked clears every
    // per-stream map and wakes the pump, so without the check the id goes back
    // into a set nothing will remove again.
    if (endStream && _activeStreams.containsKey(streamId)) {
      _halfClosedLocal.add(streamId);
    }

    if (_logger?.isInternal ?? false) {
      _logger?.internal(
        'Sent ${data.length} byte(s) for stream $streamId '
        '(endStream: $endStream)',
      );
    }
  }

  @override
  Future<void> finishSending(int streamId) async {
    if (_isClosed) return;

    final stream = _activeStreams[streamId];
    if (stream == null) return;

    // Idempotent, like RpcChannelTransport.finishSending: a caller that
    // already passed `endStream: true` to sendMessage/sendMetadata has closed
    // the request direction, and a second END_STREAM would be a DATA frame on
    // a half-closed stream -- a CONNECTION error in HTTP/2.
    if (_halfClosedLocal.contains(streamId)) {
      if (_logger?.isInternal ?? false) {
        _logger?.internal(
          'Stream $streamId is already finished; nothing to do',
        );
      }
      return;
    }

    // END_STREAM WITHOUT waiting on the peer's window: a half-close is a
    // signal, not payload, and it must not hang on a dead peer.
    final pump = _outgoingPumps[streamId];
    if (pump != null) {
      pump.endStreamNow();
    } else {
      stream.sendData(Uint8List(0), endStream: true);
    }
    _halfClosedLocal.add(streamId);

    if (_logger?.isInternal ?? false) {
      _logger?.internal('Finished sending for stream $streamId');
    }
  }

  int _policyViolations = 0;

  @override
  Stream<RpcTransportMessage> get incomingMessages => _messageController.stream;

  /// Always METERED, on the first call and on a repeat.
  ///
  /// Wrapping only the freshly-created controller and handing an existing one
  /// back raw is the shape to avoid: the second consumer of a stream then never
  /// discharges its budget, so [_fcOutstanding] only climbs and the call is
  /// refused at the window for bytes it did in fact consume. The responder
  /// sibling meters both paths.
  @override
  Stream<RpcTransportMessage> getMessagesForStream(int streamId) =>
      _fcMetered(streamId, _streams[streamId]);

  /// Bytes delivered to this call's consumer but not yet taken, per stream.
  final Map<int, int> _fcOutstanding = {};

  /// Streams already failed for overrunning [_fcWindow].
  final Set<int> _fcRefused = {};

  @override
  Future<RpcHealthStatus> health() async {
    final details = _buildHealthDetails();

    // close() is terminal; a failed reconnect is not, and is reported below as
    // degraded, so a supervisor can act on it.
    if (_messageController.isClosed || _isClosed) {
      return RpcHealthStatus.closed(
        component: runtimeType.toString(),
        message: 'HTTP/2 transport closed',
        details: details,
      );
    }

    if (_disconnected) {
      return RpcHealthStatus.degraded(
        component: runtimeType.toString(),
        message: 'HTTP/2 connection is down. Reconnect is required.',
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

    // Ask the connection, do not assume. Nothing sets `_disconnected` when the
    // PEER dies on its own -- that path runs no code here at all -- so health()
    // reported "transport ready" with the server gone. A supervisor that polls
    // health to decide whether to reconnect would never reconnect.
    //
    // Note this is the REPORT, not a refusal: a dead or drained connection
    // answers UNAVAILABLE from the send path and stays retryable, which two
    // tests pin deliberately ("a drained connection is retried as the retry doc
    // promises", "a dead connection is UNAVAILABLE (reconnect), not
    // saturated"). `_ensureUsable` is NOT wired to this on purpose — routing it
    // here turns both of those retries into a FAILED_PRECONDITION nobody
    // retries.
    //
    // Measured: server stopped, then
    //   isClosed        : false
    //   health          : HTTP/2 transport ready   <-- the peer was gone
    //   call after death: caught StateError
    // The call already failed honestly; only the report was wrong.
    if (!_connection.isOpen) {
      // Not-open with streams in flight is SATURATION, not death: the
      // connection is at the peer's MAX_CONCURRENT_STREAMS and is actively
      // serving. Reporting it "down / reconnect required" would make a
      // supervisor drop a healthy connection and every call on it. Only
      // not-open with no active streams is a finishing/terminated connection.
      // See the same split in sendMetadata().
      // Draining is not capacity. See the same split in sendMetadata().
      if (_drainSignal.goawayReceived) {
        return RpcHealthStatus.degraded(
          component: runtimeType.toString(),
          message:
              'HTTP/2 connection is draining (peer sent GOAWAY). Reconnect is '
              'required; ${_activeStreams.length} call(s) still finishing.',
          details: details,
        );
      }
      if (_activeStreams.isNotEmpty) {
        return RpcHealthStatus.healthy(
          component: runtimeType.toString(),
          message:
              'HTTP/2 transport at capacity: ${_activeStreams.length} streams '
              'in flight (server MAX_CONCURRENT_STREAMS reached)',
          details: details,
        );
      }
      return RpcHealthStatus.degraded(
        component: runtimeType.toString(),
        message: 'HTTP/2 connection is down. Reconnect is required.',
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
  Future<RpcHealthStatus> reconnect() {
    // SINGLE-FLIGHT, for the same reason as the websocket caller (473789b9).
    // The check-after-await below handles close() landing mid-reconnect, but
    // nothing stopped a SECOND reconnect interleaving: both discarded the
    // connection, both awaited the factory, and both assigned `_connection`,
    // so the second overwrote the first -- whose connection was live and no
    // longer referenced by anything that could close it.
    //
    // Measured through the stalling CONNECT proxy (400ms), counting
    // connections the server saw, after close():
    //
    //   one reconnect (control) : opened=2 closed=2 live=0
    //   two concurrent          : opened=3 closed=2 live=1
    //   three concurrent        : opened=4 closed=2 live=2
    //
    // One orphan per extra attempt, and on HTTP/2 each orphan is a whole
    // connection with its own streams and subscriptions.
    //
    // Joining rather than refusing: every caller wants the same thing, so they
    // all get the outcome of the attempt that ran.
    final inFlight = _reconnecting;
    if (inFlight != null) return inFlight;
    final attempt = _reconnectOnce().whenComplete(() => _reconnecting = null);
    _reconnecting = attempt;
    return attempt;
  }

  /// The attempt currently in flight, so concurrent callers join it.
  Future<RpcHealthStatus>? _reconnecting;

  @override
  Future<void> close() async {
    if (_isClosed) return;

    _logger?.info('Closing the HTTP/2 transport');
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
    final streamsToClose = _activeStreams.values.toList();
    for (final stream in streamsToClose) {
      try {
        stream.terminate();
        if (_logger?.isInternal ?? false) {
          _logger?.internal('RST_STREAM on stream ${stream.id} during close');
        }
      } catch (e) {
        _logger?.warning('Error closing stream ${stream.id}: $e');
      }
    }
    _activeStreams.clear();

    final subscriptionsToCancel = List<StreamSubscription<void>>.from(
      _streamSubscriptions.values,
    );
    for (final subscription in subscriptionsToCancel) {
      try {
        await subscription.cancel();
      } catch (e) {
        _logger?.warning('Error cancelling a subscription: $e');
      }
    }
    _streamSubscriptions.clear();
    // Release every producer parked on a server window before the streams go.
    for (final pump in _outgoingPumps.values) {
      pump.dispose();
    }
    _outgoingPumps.clear();

    _streamParsers.clear();
    _initialHeadersReceived.clear();
    _halfClosedLocal.clear();
    _reservedStreams.clear();
    _statusReceived.clear();

    _streams.closeAll();

    if (!_messageController.isClosed) {
      try {
        await _messageController.close();
      } catch (e) {
        _logger?.warning('Error closing the message controller: $e');
      }
    }
    if (!_lostCtl.isClosed) await _lostCtl.close();

    // BOUNDED, then forceful -- see [kGracefulCloseTimeout], which the
    // responder transport shares.
    try {
      await _connection.finish().timeout(kGracefulCloseTimeout);
    } catch (e) {
      _logger?.warning(
        'Graceful HTTP/2 shutdown did not complete ($e); terminating',
      );
      try {
        unawaited(_connection.terminate());
      } catch (e2) {
        _logger?.warning('Error closing the HTTP/2 connection: $e2');
      }
    }

    _logger?.info('HTTP/2 transport closed');
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
