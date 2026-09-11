// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';
import 'dart:convert';
import 'package:http2/http2.dart' as http2;
import 'package:rpc_dart/rpc_dart.dart';
import 'package:universal_io/io.dart';

import 'http2_header_block_guard.dart';
import 'rpc_http2_common.dart';

/// Whether the peer has told us this connection is going away.
///
/// A mutable holder rather than a field because the connection is built by a
/// static factory closure BEFORE the transport instance exists, and the same
/// closure is re-run by [RpcHttp2CallerTransport.reconnect]. One holder per
/// transport, shared with every connection it builds, reset on attach.
class _DrainSignal {
  bool goawayReceived = false;
}

/// Client-side HTTP/2 transport: one [IRpcTransport] over one connection,
/// multiplexing outgoing RPC calls on the gRPC-compatible wire format.
///
/// Declares [IRpcSecurityPolicyAware] because the endpoint layers find the
/// policy with an `is` check: a transport that does not declare it silently
/// gets `const RpcSecurityPolicy()` instead of the configured one.
class RpcHttp2CallerTransport
    implements
        IRpcTransport,
        IRpcStreamReset,
        IRpcSecurityPolicyAware,
        IRpcStreamIdSequence {
  @override
  bool get isClient => true;

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

  /// Rebuilds the connection on [reconnect].
  final Future<http2.ClientTransportConnection> Function() _connectionFactory;

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

  /// How long [close] lets the graceful HTTP/2 shutdown run before forcing it.
  ///
  /// Short on purpose: close() has already RST'd every stream still open
  /// locally by the time it calls `finish()`, so a healthy connection finishes
  /// in milliseconds (measured: 104 ms end to end). The budget exists only so a
  /// peer that never answers cannot hold shutdown open forever.
  static const Duration _gracefulCloseTimeout = Duration(seconds: 2);

  /// Refuses work the transport genuinely cannot do, naming which state it is
  /// in, because the two are not recoverable in the same way.
  void _ensureUsable() {
    if (_isClosed) throw StateError('Transport is closed');
    if (_disconnected) {
      throw StateError(
        'Transport is disconnected and has no connection; call reconnect(). '
        'A failed reconnect leaves the transport recoverable, not closed.',
      );
    }
  }

  final LogScope? _logger;

  final RpcSecurityPolicy _policy;

  RpcHttp2CallerTransport._({
    required http2.ClientTransportConnection connection,
    required Future<http2.ClientTransportConnection> Function()
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
    _startKeepalive();
  }

  /// Set once the peer sends GOAWAY on the current connection.
  ///
  /// `ClientTransportConnection.isOpen` is
  /// `!isFinishing && !isTerminated && canOpenStream`, so on its own it cannot
  /// tell a DRAINING peer from one merely at MAX_CONCURRENT_STREAMS — and the
  /// two need opposite responses: reconnect elsewhere versus wait for a slot.
  /// The header-block guard already parses frame headers on this connection's
  /// incoming bytes, so it reports GOAWAY (frame type 0x7) here.
  final _DrainSignal _drainSignal;

  /// (Re)starts PING keepalive for the current connection.
  ///
  /// Called from the constructor and again after [reconnect] swaps
  /// `_connection`: a timer left pointing at the old connection would ping a
  /// corpse forever and never probe the live one.
  ///
  /// A dead peer never answers, so `ping()` simply never completes — the
  /// timeout is what actually detects the half-open path. On failure the
  /// connection is TERMINATED, never finished: `finish()` on a connection whose
  /// peer is gone throws from package:http2 into the root zone. Terminating
  /// makes `isOpen` false, so pending calls fail UNAVAILABLE and health()
  /// reports the connection down — which is what a supervisor needs in order to
  /// reconnect.
  ///
  /// Every await is guarded: this runs on a detached timer callback, where an
  /// unhandled async error reaches the root zone and kills the isolate.
  void _startKeepalive() {
    _keepalive?.cancel();
    final interval = _pingInterval;
    if (interval == null) return;
    final timeout = _pingTimeout ?? interval;
    final connection = _connection;

    var inFlight = false;
    _keepalive = Timer.periodic(interval, (timer) async {
      // One probe at a time: a slow-but-alive peer must not accumulate pings,
      // and a stalled one would otherwise start a new one every interval.
      if (inFlight) return;
      if (_isClosed) {
        timer.cancel();
        return;
      }
      inFlight = true;
      try {
        await connection.ping().timeout(timeout);
      } catch (error) {
        timer.cancel();
        _logger?.warning(
          'HTTP/2 keepalive failed for $_host:$_port ($error); the path is '
          'half-open, tearing the connection down so calls fail fast',
        );
        _disconnected = true;
        _discardConnection(connection);
        return;
      } finally {
        inFlight = false;
      }
    });
  }

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
          policy: policy,
          logger: logger,
        );
      }
      final socket = await SecureSocket.connect(
        host,
        port,
        supportedProtocols: ['h2'],
      );
      // The proxy path below has always done this; the direct path had not, so
      // the same class produced differently configured sockets. See
      // disableNagle.
      disableNagle(socket, logger: logger, what: 'h2 socket to $host:$port');
      return _guardedConnection(
        incoming: socket,
        outgoing: socket,
        destroy: socket.destroy,
        policy: policy,
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
      logger: logger,
      drainSignal: drainSignal,
    );
    return RpcHttp2CallerTransport._(
      connection: connection,
      connectionFactory: () => throw StateError(
        'RpcHttp2CallerTransport.viaSocket does not support reconnect: '
        'the originating socket cannot be recreated.',
      ),
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
          policy: policy,
          logger: logger,
        );
      }
      final socket = await Socket.connect(host, port);
      // See disableNagle: same reason as the h2c/TLS and proxy paths.
      disableNagle(socket, logger: logger, what: 'h2c socket to $host:$port');
      return _guardedConnection(
        incoming: socket,
        outgoing: socket,
        destroy: socket.destroy,
        policy: policy,
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

  /// Ceiling on a proxy's CONNECT response headers.
  ///
  /// `headerBuf` accumulates until CRLFCRLF appears, so an unbounded read makes
  /// a proxy that streams headers forever an OOM on the CLIENT. A real CONNECT
  /// response is a status line and a handful of headers; 64 KiB is already
  /// absurdly generous.
  ///
  /// A proxy is a machine on the path and often not the operator's, so trusting
  /// it without bound is the wrong default.
  static const int _maxProxyHeaderBytes = 64 * 1024;

  /// Builds the http2 connection with the peer's header blocks bounded.
  ///
  /// A CLIENT is exposed to the CONTINUATION flood exactly as the server was
  /// (fixed for RpcHttp2Server in the previous round): package:http2
  /// concatenates a HEADERS frame and its CONTINUATION frames into one
  /// unbounded buffer, rebuilding it on every frame, and does so BEFORE any
  /// stream-state handling -- so the stream need not even exist and nothing
  /// above the transport can see it.
  ///
  /// A hostile server answering with HEADERS that lack END_HEADERS and then
  /// CONTINUATION frames forever costs the CLIENT more RSS than the same flood
  /// costs the server, with the transport still reporting open throughout.
  ///
  /// "You dialed the server" is not a defence: a client gets pointed at a
  /// compromised endpoint, and a proxy is a machine on the path that is often
  /// not the operator's — the same reasoning that bounds the CONNECT response
  /// in [_maxProxyHeaderBytes].
  ///
  /// [skipConnectionPreface] is false here and must stay false: the 24-octet
  /// preface travels client-to-server only, so a client that skipped 24 bytes
  /// would misparse the server's first frames.
  static http2.ClientTransportConnection _guardedConnection({
    required Stream<List<int>> incoming,
    required StreamSink<List<int>> outgoing,
    required void Function() destroy,
    required RpcSecurityPolicy policy,
    LogScope? logger,
    _DrainSignal? drainSignal,
  }) {
    final guarded = guardHttp2HeaderBlock(
      incoming,
      maxHeaderBlockBytes: policy.maxMetadataBytes,
      skipConnectionPreface: false,
      onGoaway: () {
        logger?.internal(
          'HTTP/2 peer sent GOAWAY: this connection is draining',
        );
        drainSignal?.goawayReceived = true;
      },
      onViolation: (observedBytes) {
        logger?.warning(
          'HTTP/2 header-block cap exceeded by the peer: $observedBytes bytes '
          '(max: ${policy.maxMetadataBytes}); closing connection',
        );
        destroy();
      },
    );
    return http2.ClientTransportConnection.viaStreams(guarded, outgoing);
  }

  /// Establishes an HTTP/2 connection through an HTTP CONNECT proxy.
  ///
  /// The handshake uses a SINGLE, persistent socket subscription — kept alive
  /// for a plaintext tunnel, cancelled before the TLS upgrade. Re-subscribing
  /// to a single-subscription Socket stream throws StateError the moment http2
  /// calls `socket.listen()` again.
  static Future<http2.ClientTransportConnection> _connectH2ViaProxy({
    required Uri proxyUri,
    required String targetHost,
    required int targetPort,
    required bool secure,
    required RpcSecurityPolicy policy,
    Duration handshakeTimeout = _proxyHandshakeTimeout,
    LogScope? logger,
  }) async {
    final proxyHost = proxyUri.host;
    final proxyPort = proxyUri.hasPort ? proxyUri.port : 3128;

    final rawSocket = await Socket.connect(proxyHost, proxyPort);
    // This is the path that already did it, and the reason the other two
    // stood out. Routed through the shared helper so a setOption that throws
    // on a socket the proxy has already reset cannot take the isolate out.
    disableNagle(rawSocket, logger: logger, what: 'proxy socket to $proxyHost');

    // Build CONNECT request.
    final reqBuf = StringBuffer()
      ..write('CONNECT $targetHost:$targetPort HTTP/1.1\r\n')
      ..write('Host: $targetHost:$targetPort\r\n');
    if (proxyUri.userInfo.isNotEmpty) {
      reqBuf.write(
        'Proxy-Authorization: Basic ${base64Encode(utf8.encode(proxyUri.userInfo))}\r\n',
      );
    }
    reqBuf.write('\r\n');
    rawSocket.add(utf8.encode(reqBuf.toString()));

    // Single subscription kept alive for the full lifetime of the tunnel.
    // For non-TLS: data after CONNECT headers is forwarded to [forwardCtrl],
    //   and http2 reads from forwardCtrl.stream via viaStreams.
    // For TLS: subscription is cancelled after CONNECT so SecureSocket can
    //   attach its own listener via _detachRaw() / SecureSocket.secure().
    final forwardCtrl = StreamController<List<int>>();
    final handshake = Completer<void>();
    bool headersDone = false;
    final headerBuf = <int>[];

    final sub = rawSocket.listen(
      (chunk) {
        if (headersDone) {
          if (!forwardCtrl.isClosed) forwardCtrl.add(chunk);
          return;
        }
        headerBuf.addAll(chunk);
        if (headerBuf.length > _maxProxyHeaderBytes) {
          rawSocket.destroy();
          if (!handshake.isCompleted) {
            handshake.completeError(
              SocketException(
                'HTTP proxy sent more than $_maxProxyHeaderBytes bytes of '
                'CONNECT response headers without terminating them',
              ),
            );
          }
          return;
        }
        final endIdx = _indexOfEndOfHeaders(headerBuf);
        if (endIdx == -1) return;

        headersDone = true;
        final statusLine = String.fromCharCodes(headerBuf).split('\r\n').first;
        if (!RegExp(r'HTTP/\S+ 2\d\d').hasMatch(statusLine)) {
          rawSocket.destroy();
          if (!handshake.isCompleted) {
            handshake.completeError(
              SocketException(
                'HTTP proxy CONNECT rejected: ${statusLine.trim()}',
              ),
            );
          }
          return;
        }
        // Bytes after \r\n\r\n (unusual but possible): forward immediately.
        final leftover = headerBuf.sublist(endIdx + 4);
        if (leftover.isNotEmpty && !forwardCtrl.isClosed) {
          forwardCtrl.add(Uint8List.fromList(leftover));
        }
        if (!handshake.isCompleted) handshake.complete();
      },
      onError: (Object e) {
        if (!handshake.isCompleted) {
          handshake.completeError(e);
        } else if (!forwardCtrl.isClosed) {
          forwardCtrl.addError(e);
        }
      },
      onDone: () {
        if (!handshake.isCompleted) {
          handshake.completeError(
            SocketException('Proxy closed during CONNECT'),
          );
        }
        if (!forwardCtrl.isClosed) forwardCtrl.close();
      },
    );

    // Bounded, and the socket is released on the way out: abandoning the await
    // without destroying the socket would leak it -- Future.timeout abandons
    // the await, not the work.
    try {
      await handshake.future.timeout(handshakeTimeout);
    } catch (error) {
      await sub.cancel();
      // NOT awaited. `forwardCtrl` is single-subscription and nothing has
      // listened to it on this path, and closing a never-listened controller
      // returns a future that does not complete until someone does. Awaiting
      // it deadlocked the very timeout being added here: the 2s bound fired
      // and then cleanup hung forever, which looked exactly like no timeout at
      // all.
      unawaited(forwardCtrl.close());
      rawSocket.destroy();
      if (error is TimeoutException) {
        throw SocketException(
          'HTTP proxy did not answer CONNECT within $handshakeTimeout',
        );
      }
      rethrow;
    }

    if (secure) {
      // Cancel our sub so SecureSocket.secure() (via _detachRaw) can attach.
      await sub.cancel();
      // NOT awaited, for the same reason as the timeout path above: on the TLS
      // branch nothing ever listens to `forwardCtrl` (http2 reads from the
      // SecureSocket instead), so awaiting its close never returns and
      // secureConnect through a proxy hung forever AFTER a successful CONNECT
      // handshake -- TLS was never even attempted.
      unawaited(forwardCtrl.close());
      final secureSocket = await SecureSocket.secure(
        rawSocket,
        host: targetHost,
        supportedProtocols: ['h2'],
      );
      return _guardedConnection(
        incoming: secureSocket,
        outgoing: secureSocket,
        destroy: secureSocket.destroy,
        policy: policy,
        logger: logger,
      );
    } else {
      // Keep sub alive — it feeds forwardCtrl.
      // http2 reads from forwardCtrl.stream; writes go directly to rawSocket.
      // The guard sits on the forwarded stream, so it bounds what the TUNNELED
      // peer sends as well as anything the proxy injects.
      return _guardedConnection(
        incoming: forwardCtrl.stream,
        outgoing: rawSocket,
        destroy: rawSocket.destroy,
        policy: policy,
        logger: logger,
      );
    }
  }

  static int _indexOfEndOfHeaders(List<int> bytes) {
    for (var i = 0; i <= bytes.length - 4; i++) {
      if (bytes[i] == 0x0D &&
          bytes[i + 1] == 0x0A &&
          bytes[i + 2] == 0x0D &&
          bytes[i + 3] == 0x0A) {
        return i;
      }
    }
    return -1;
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
    if (_reservedStreams.length >= _policy.maxActiveStreams) {
      throw StateError(
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

    final methodPath = metadata.methodPath ?? '/Unknown/Unknown';

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
      authority: _host,
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
        throw RpcStatusException(
          RpcStatus.resourceExhausted,
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

    stream.terminate();
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
      throw StateError('Stream $streamId not found. Send metadata first.');
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
    if (endStream) _halfClosedLocal.add(streamId);

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

  Map<String, Object?> _buildHealthDetails() => {
    'isClosed': _isClosed,
    'disconnected': _disconnected,
    'connectionOpen': _connection.isOpen,
    'activeStreams': _activeStreams.length,
    'pendingSubscriptions': _streamSubscriptions.length,
    'pendingParsers': _streamParsers.length,
    'host': _host,
    'port': _port,
    'scheme': _scheme,
    'messageControllerClosed': _messageController.isClosed,
  };

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
            stackTrace,
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
            stackTrace,
          );
          return;
        }

        _emitStreamError(streamId, error, stackTrace);
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
          _logger?.warning(
            'Stream $streamId ended without a gRPC status; reporting '
            'UNAVAILABLE rather than a clean end',
          );
          _emit(
            RpcTransportMessage(
              streamId: streamId,
              metadata: RpcMetadata([
                RpcHeader(
                  RpcHeaders.grpcStatus,
                  RpcStatus.unavailable.toString(),
                ),
                RpcHeader(
                  RpcHeaders.grpcMessage,
                  RpcMetadata.encodeGrpcMessage(
                    'Response ended without a gRPC status (connection lost '
                    'or stream reset before trailers)',
                  ),
                ),
              ]),
              isEndOfStream: true,
              methodPath: methodPath,
            ),
          );
        }

        _activeStreams.remove(streamId);
        _streamSubscriptions.remove(streamId);
        _streamParsers.remove(streamId);
        _initialHeadersReceived.remove(streamId);
        _halfClosedLocal.remove(streamId);
        _reservedStreams.remove(streamId);
        _statusReceived.remove(streamId);
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

      _emitStreamError(streamId, e, stackTrace);
    }
  }

  /// Handles an incoming HEADERS frame (initial response or trailers).
  void _handleHeadersMessage(
    int streamId,
    http2.HeadersStreamMessage message,
    String methodPath,
  ) {
    // Check :status pseudo-header (present only in initial response, not trailers).
    final httpStatus = extractHttpStatus(message.headers);

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
      return;
    }

    // Track initial vs trailer headers.
    final isInitialHeaders = !_initialHeadersReceived.contains(streamId);
    if (isInitialHeaders) {
      _initialHeadersReceived.add(streamId);
    }

    // Pseudo-headers are filtered out by the converter.
    // A client is exposed to the same flood from the server it dialled.
    final metadata = http2HeadersToRpcMetadata(
      message.headers,
      policy: _policy,
    );
    _policy.validateMetadata(metadata);

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
    // content-type. Absent is accepted rather than rejected, matching the check
    // the responder pipeline already applies in the other direction -- being
    // strict here would be a new policy, not a fix.
    if (isInitialHeaders) {
      final contentType = metadata.getHeaderValue(RpcHeaders.contentType);
      if (contentType != null &&
          !contentType.toLowerCase().startsWith(RpcHeaders.contentTypeGrpc)) {
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
        return;
      }
    }

    // Build the transport message.
    final transportMessage = RpcTransportMessage(
      streamId: streamId,
      metadata: metadata,
      isEndOfStream: message.endStream,
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
        final framedMessage = ensureGrpcFrame(messages[i]);
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

      _emitStreamError(streamId, e, stackTrace);
    }
  }

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

  /// How much un-consumed RESPONSE payload one call may hold; the responder's
  /// `_fcWindow` bounds the request direction with the same number.
  int get _fcWindow => unconsumedWindowFor(_policy);

  /// Bytes delivered to this call's consumer but not yet taken, per stream.
  final Map<int, int> _fcOutstanding = {};

  /// Streams already failed for overrunning [_fcWindow].
  final Set<int> _fcRefused = {};

  /// Bounds a response a consumer has stopped reading.
  ///
  /// This used to be a demand hop -- `onPause`/`onResume` forwarding to the
  /// http2 subscription -- because on HTTP/2 the lever that slows a server is
  /// the h2 window, which only closes if we stop READING. Without any bound at
  /// all a paused client never slowed the server down: measured with a
  /// server-stream handler and a client that paused after 5 items, the handler
  /// produced 33906 more (132.4 MiB) in 4 s and was still climbing, against
  /// 1023 (4.0 MiB, flat) over websocket.
  ///
  /// But pausing parks bytes in package:http2's connection-level queue, and a
  /// reset then discards them without crediting the connection window -- so
  /// cancelling a paused download killed the whole connection, measured, in
  /// exactly the way it did on the responder side. See the responder's
  /// `_fcWindow` for the mechanism and the numbers.
  ///
  /// So the budget is kept and the CALL is failed past it, while reading never
  /// stops. `map` is lazy, so a consumer that stops pulling stops discharging.
  Stream<RpcTransportMessage> _fcMetered(
    int streamId,
    Stream<RpcTransportMessage> source,
  ) => source.map((message) {
    _fcDischarge(streamId, message.payload?.length ?? 0);
    return message;
  });

  void _fcDischarge(int streamId, int bytes) {
    if (bytes <= 0) return;
    final left = (_fcOutstanding[streamId] ?? 0) - bytes;
    if (left <= 0) {
      _fcOutstanding.remove(streamId);
    } else {
      _fcOutstanding[streamId] = left;
    }
  }

  void _fcOnDelivered(int streamId, int bytes) {
    if (bytes <= 0 || !_streams.contains(streamId)) return;
    final now = (_fcOutstanding[streamId] ?? 0) + bytes;
    _fcOutstanding[streamId] = now;
    if (now <= _fcWindow || !_fcRefused.add(streamId)) return;
    _logger?.warning(
      'Stream $streamId holds $now un-consumed response bytes '
      '(window: $_fcWindow); failing the call',
    );
    // Order matters: the error goes out FIRST, because resetStream records the
    // id in _resetStreams and _emitStreamError deliberately suppresses errors
    // for a stream we reset ourselves.
    _emitStreamError(
      streamId,
      RpcStatusException(
        RpcStatus.resourceExhausted,
        'Response exceeds the un-consumed window ($now > $_fcWindow bytes)',
      ),
    );
    // Then RST_STREAM, or the server never learns and keeps producing for a
    // consumer that is gone -- the same trap the responder's `onTerminated`
    // comment records from the other side.
    unawaited(
      resetStream(
        streamId,
        reason: 'un-consumed response window exceeded',
      ).catchError((Object _) => false),
    );
  }

  void _fcForget(int streamId) {
    _fcOutstanding.remove(streamId);
    _fcRefused.remove(streamId);
  }

  /// Routes an incoming message to the shared broadcast and to its own stream.
  void _emit(RpcTransportMessage message) {
    // Charge before delivering: a consumer that takes it synchronously
    // discharges immediately afterwards, and crediting a charge that has not
    // happened yet would clamp the counter at zero.
    _fcOnDelivered(message.streamId, message.payload?.length ?? 0);
    if (!_messageController.isClosed) _messageController.add(message);
    _streams.add(message);
    if (message.isEndOfStream) _fcForget(message.streamId);
  }

  /// Routes a stream-scoped error: raw on the dedicated controller, enveloped
  /// on the broadcast (so it does not leak onto unrelated streams there).
  void _emitStreamError(int streamId, Object error, [StackTrace? stackTrace]) {
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
        RpcHttp2StreamError(streamId, error, stackTrace),
      );
    }
  }

  @override
  Future<RpcHealthStatus> health() async {
    final details = _buildHealthDetails();

    if (_messageController.isClosed) {
      return RpcHealthStatus.closed(
        component: runtimeType.toString(),
        message: 'HTTP/2 transport closed',
        details: details,
      );
    }

    // close() is terminal; a failed reconnect is not. Reporting the second as
    // "closed" was what made the advice below unfollowable.
    if (_isClosed) {
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

    // Ask the connection, do not assume. Nothing sets `_disconnected` when the
    // PEER dies on its own -- that path runs no code here at all -- so health()
    // reported "transport ready" with the server gone. A supervisor that polls
    // health to decide whether to reconnect would never reconnect.
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

  /// Shuts down a connection this transport has decided to abandon.
  ///
  /// Runs inside [runZonedGuarded] rather than behind a `catchError`. Finishing
  /// a connection whose socket is already gone makes package:http2 throw
  /// `Bad state: Cannot add event after closing` from its own frame writer,
  /// asynchronously and OUTSIDE the future returned here — so a `catchError`
  /// does not see it and it reaches the root zone, where an unhandled async
  /// error kills the isolate. Observed exactly that while building this path.
  void _discardConnection(http2.ClientTransportConnection connection) {
    try {
      connection.terminate();
    } catch (e) {
      _logger?.warning('Discarding abandoned connection failed: $e');
    }
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

  Future<RpcHealthStatus> _reconnectOnce() async {
    if (_messageController.isClosed) {
      return RpcHealthStatus.closed(
        component: runtimeType.toString(),
        message: 'Transport is closed and cannot be reconnected',
        details: {..._buildHealthDetails(), 'supported': false},
      );
    }

    _logger?.info('Reconnecting the HTTP/2 client to $_host:$_port');

    // terminate(), not finish(). finish() writes a GOAWAY, and reconnect is
    // called precisely when the connection is already gone -- either the peer
    // died, or an earlier reconnect finished this very connection. Writing to a
    // closed frame writer makes package:http2 throw
    //
    //   Bad state: Cannot add event after closing
    //     package:http2 ... FrameWriter.writeGoawayFrame
    //     asynchronous gap
    //     package:http2/src/connection.dart  Connection._setupConnection
    //
    // ASYNCHRONOUSLY, from a subscription it created in the ROOT zone. The
    // try/catch below never saw it, and an unhandled async error in the root
    // zone kills the isolate. Reproduced by simply calling reconnect() twice.
    //
    // _discardConnection exists for exactly this and is already used on the
    // abandon path; the prologue just never used it.
    _discardConnection(_connection);

    for (final subscription in _streamSubscriptions.values) {
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
    _activeStreams.clear();
    _initialHeadersReceived.clear();
    _halfClosedLocal.clear();
    _reservedStreams.clear();
    _statusReceived.clear();

    try {
      final connection = await _connectionFactory();

      // Re-check AFTER the factory. The guard at the top of this method runs
      // before every await here, and opening a connection takes real time, so
      // close() lands inside that window. Two things went wrong when it did:
      // the new connection was attached to a transport the caller had already
      // closed (nothing holds it, so it can never be closed), and
      // `_isClosed = false` below UN-CLOSED the transport, so isClosed lied.
      //
      // Measured through the CONNECT-proxy path, which stalls the factory the
      // way a real network does (400ms), with close() 20ms in:
      //
      //   control, plain connect + close : live=0  isClosed=true
      //   close during reconnect, before : live=1  isClosed true -> FALSE,
      //                                    reconnect reported HEALTHY
      //   close during reconnect, after  : live=0  isClosed stays true
      //
      // Same defect as RpcClientConnection in core (334b3337) and
      // RpcWebSocketCallerTransport (32966691), both of which checked before
      // the await and not after. This one is worse because of the un-close.
      if (_isClosed || _messageController.isClosed) {
        _discardConnection(connection);
        return RpcHealthStatus.closed(
          component: runtimeType.toString(),
          message: 'Transport closed during reconnect',
          details: {..._buildHealthDetails(), 'supported': true},
        );
      }

      _connection = connection;
      _disconnected = false;
      // `_nextStreamId` is deliberately NOT reset here.
      //
      // It used to be, and that handed the first call on the new connection the
      // id a call from the old one still held. This id is rpc_dart's own handle
      // — package:http2 assigns the real HTTP/2 stream ids itself in
      // `makeRequest`, and `_activeStreams` is keyed by the handle — so nothing
      // about the protocol requires it to restart, while everything about
      // teardown requires it not to: a caller releases its id and half-closes
      // by id, and the id is all it has to present.
      //
      // Measured, one reconnect between two calls, with the first still open:
      //
      //   before: A and B both get id 1, and B's `getMessagesForStream(1)`
      //           throws "Bad state: Stream has already been listened to" —
      //           A's controller is still registered under that id
      //   after : A keeps 1, B gets 3, both served
      //
      // The websocket sibling had the same defect in quieter form (there the
      // ids collide silently and a dead call's `finishSending` HALF-CLOSES the
      // live one). Fixed there by continuing the id sequence across the swap;
      // same principle, one line here.
      // The signal is per-TRANSPORT but describes the CURRENT connection, and
      // the factory closure reports every connection into the same holder. A
      // stale flag here would make a freshly reconnected transport claim it was
      // draining and refuse every call.
      _drainSignal.goawayReceived = false;
      // Re-arm keepalive against the NEW connection. The old timer closed over
      // the old one, so without this a reconnected transport either pings a
      // corpse forever or (after a keepalive-triggered teardown, which cancels
      // the timer) is left with no keepalive at all — blind again after exactly
      // the first drop, which is when a flaky path is most likely.
      _startKeepalive();
      _logger?.info('HTTP/2 client reconnected');
      return RpcHealthStatus.healthy(
        component: runtimeType.toString(),
        message: 'HTTP/2 connection re-established',
        details: {..._buildHealthDetails(), 'supported': true},
      );
    } catch (error, stackTrace) {
      // NOT _isClosed: the caller did not close this transport, it merely has
      // no connection right now. Marking it closed made the first failure
      // terminal -- retry-with-backoff, the only way anyone drives reconnect,
      // could never recover.
      _disconnected = true;
      _logger?.error(
        'Failed to reconnect the HTTP/2 client',
        error: error,
        stackTrace: stackTrace,
      );
      return RpcHealthStatus.unhealthy(
        component: runtimeType.toString(),
        message: 'Failed to reconnect HTTP/2 transport: $error',
        details: {
          ..._buildHealthDetails(),
          'supported': true,
          'error': error.toString(),
        },
      );
    }
  }

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

    // A short grace period for streams still finishing.
    if (_activeStreams.isNotEmpty) {
      if (_logger?.isInternal ?? false) {
        _logger?.internal(
          'Waiting on ${_activeStreams.length} active stream(s)',
        );
      }
      await Future<void>.delayed(Duration(milliseconds: 50));
    }

    // Abort EVERY remaining stream, half-closed ones INCLUDED.
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
        try {
          stream.terminate();
        } catch (e2) {
          _logger?.warning('Error terminating stream ${stream.id}: $e2');
        }
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

    // BOUNDED, then forceful. `finish()` is the graceful HTTP/2 shutdown: it
    // sends GOAWAY and waits for open streams to drain. Over a HALF-OPEN path
    // the peer drains nothing, so that await never completes and close() hangs
    // forever -- with an in-flight stream as the load-bearing condition, since
    // with none open finish() returns promptly even on a dead path.
    //
    // Timing out alone is not enough: Future.timeout abandons the await, not
    // the work, so the connection would stay alive and unreferenced.
    // terminate() is what releases it, and is the right primitive on a dead
    // connection anyway -- finish() on one throws from package:http2 into the
    // root zone.
    try {
      await _connection.finish().timeout(_gracefulCloseTimeout);
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
    throw UnimplementedError('Unsupport direct object sending');
  }

  @override
  bool get supportsZeroCopy => false;
}
