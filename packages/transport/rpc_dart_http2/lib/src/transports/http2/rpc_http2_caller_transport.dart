// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';
import 'dart:convert';
import 'package:universal_io/io.dart';

import 'package:http2/http2.dart' as http2;
import 'package:rpc_dart/rpc_dart.dart';

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

/// HTTP/2 транспорт для клиентских RPC вызовов
///
/// Реализует IRpcTransport поверх HTTP/2 протокола для исходящих вызовов.
/// Поддерживает мультиплексирование потоков и gRPC-совместимый протокол.
///
/// Реализует [IRpcSecurityPolicyAware]: слои эндпоинта определяют политику
/// через `is`-проверку, поэтому транспорт, который её не объявляет, получает
/// `const RpcSecurityPolicy()` вместо настроенной приложением.
class RpcHttp2CallerTransport
    implements IRpcTransport, IRpcStreamReset, IRpcSecurityPolicyAware {
  @override
  bool get isClient => true;

  @override
  RpcSecurityPolicy get securityPolicy => _policy;

  /// HTTP/2 соединение
  http2.ClientTransportConnection _connection;

  /// Фабрика для повторного создания соединения при переподключении
  final Future<http2.ClientTransportConnection> Function() _connectionFactory;

  /// Контроллер для входящих сообщений
  final BufferedBroadcastController<RpcTransportMessage> _messageController =
      BufferedBroadcastController<RpcTransportMessage>();

  /// Per-stream dedicated controllers for [getMessagesForStream].
  ///
  /// HTTP/2 already demultiplexes by stream natively, yet every message was
  /// funnelled onto the shared broadcast above and then re-filtered per stream
  /// (O(active-streams) per message). Each stream now gets its own controller
  /// and messages are routed to it directly; the broadcast is still fed for
  /// global consumers (and keeps the [RpcHttp2StreamError] envelope semantics).
  final Map<int, StreamController<RpcTransportMessage>> _streamControllers = {};

  /// Счетчик для генерации Stream ID
  int _nextStreamId = 1; // Клиент использует нечетные ID

  /// Активные HTTP/2 streams
  final Map<int, http2.ClientTransportStream> _activeStreams = {};

  /// Подписки на входящие сообщения streams
  final Map<int, StreamSubscription> _streamSubscriptions = {};

  /// Парсеры для каждого stream (для фрагментированных сообщений)
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
  /// finished call from a truncated one. Without this, a server stream cut off
  /// by a dead peer was delivered to the consumer as a clean end -- partial
  /// data reported as complete, with no error anywhere. The websocket and
  /// isolate transports surface it as an error; only this one did not.
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

  /// Целевой хост
  final String _host;

  /// Схема (http/https)
  final String _scheme;

  /// Порт подключения
  final int _port;

  /// Флаг закрытия. Set ONLY by [close]; permanent.
  bool _isClosed = false;

  /// No live connection, but recovery is expected.
  ///
  /// A failed [reconnect] used to set [_isClosed] instead, which conflated two
  /// states that need opposite handling. [health] already read that flag as
  /// "disconnected, reconnect required" and reported DEGRADED, while the send
  /// paths read it as "closed" and the post-factory re-check in [reconnect]
  /// read it as "the caller closed us" -- so the transport told you to
  /// reconnect and then refused every attempt. One failed reconnect was
  /// terminal, even when the connection had been perfectly healthy.
  bool _disconnected = false;

  /// How often to PING an otherwise idle connection, and the ONLY way this
  /// transport detects a HALF-OPEN path.
  ///
  /// A NAT box, load balancer or mobile network that silently stops forwarding
  /// sends no FIN and no RST, so the socket still looks fine to both ends.
  /// Measured through a TCP relay frozen mid-flight, which is exactly that:
  ///
  ///     no keepalive       : the call HUNG for the full 12s and died on the
  ///                          caller's own timeout, while health() still
  ///                          reported "HTTP/2 transport ready"
  ///     pingInterval 2s    : the connection is torn down, the call fails
  ///                          UNAVAILABLE, and health() reports it down
  ///     control, no freeze : returned in 4ms
  ///
  /// The health() line is the one that matters operationally: a supervisor
  /// polling health to decide whether to reconnect sees green and never
  /// reconnects, so every call on that connection waits out its deadline.
  ///
  /// Defaults to null (OFF), so nothing changes for existing callers, and the
  /// interval is left to the deployment for the same reason as everywhere else
  /// here: too short wakes radios and wastes battery, too long leaves dead
  /// connections resident. This is the client half of
  /// `GRPC_ARG_KEEPALIVE_TIME_MS`.
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

  /// Логгер
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

  /// Создает клиентский HTTP/2 транспорт через защищенное соединение.
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
    logger?.internal('Создание защищенного HTTP/2 соединения с $host:$port');

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
    logger?.internal('HTTP/2 соединение установлено');

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

  /// Создает клиентский HTTP/2 транспорт поверх уже установленного сокета.
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

  /// Создает клиентский HTTP/2 транспорт через незащищенное соединение.
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
    logger?.internal('Создание HTTP/2 соединения с $host:$port');

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
    logger?.internal('HTTP/2 соединение установлено');

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

  /// Establishes an HTTP/2 connection through an HTTP CONNECT proxy.
  ///
  /// The CONNECT handshake is performed with a single, persistent socket
  /// subscription that is kept alive (non-TLS) or cancelled before TLS upgrade.
  /// This avoids re-subscribing to a single-subscription Socket stream, which
  /// would throw StateError when http2 tries to call socket.listen() again.
  /// How long a proxy has to answer CONNECT before the attempt is abandoned.
  ///
  /// There was no timeout at all, and `connect()` is what an application
  /// awaits at startup. Measured against a proxy that accepts the TCP
  /// connection and then says nothing: connect() was still pending after 8s
  /// and would never have settled.
  static const Duration _proxyHandshakeTimeout = Duration(seconds: 30);

  /// Ceiling on a proxy's CONNECT response headers.
  ///
  /// `headerBuf` grew until CRLFCRLF appeared, with no bound, so a proxy that
  /// streams headers forever is an OOM on the client: measured at **268 MiB of
  /// RSS in 6 seconds** and still climbing. A real CONNECT response is a status
  /// line and a handful of headers; 64 KiB is already absurdly generous.
  ///
  /// A proxy is a machine on the path and often not the operator's, so
  /// trusting it without bound is the wrong default -- the same reasoning that
  /// bounds a response body in e8c5bc9f.
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
  /// Measured against a hostile server that answers with HEADERS lacking
  /// END_HEADERS and then CONTINUATION frames forever:
  ///
  ///   64 MiB of frames -> client RSS +194.3 MiB, transport still reporting
  ///                       open
  ///
  /// which is worse than the server side measured (+53.7 MiB) for the same
  /// flood. "You dialed the server" is not a defence: a client gets pointed at
  /// a compromised endpoint, and a proxy is a machine on the path that is often
  /// not the operator's -- the same reasoning that bounds the CONNECT response
  /// in [_maxProxyHeaderBytes] and the response body in e8c5bc9f.
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
    rawSocket.setOption(SocketOption.tcpNoDelay, true);

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
    _nextStreamId += 2; // Клиент использует нечетные ID (1, 3, 5, ...)
    _reservedStreams.add(streamId);

    _logger?.internal('Создан stream: $streamId');
    return streamId;
  }

  @override
  bool releaseStreamId(int streamId) {
    if (_isClosed) return false;

    _logger?.internal('Освобождение stream: $streamId');

    // Release must not WRITE to the stream. This used to send
    // `sendData(Uint8List(0), endStream: true)`, but by the time the pipeline
    // releases an id the request direction is already finished -- every call
    // ends with END_STREAM -- so that was a DATA frame on a half-closed
    // (local) stream. package:http2 treats it as a connection error and
    // terminates the CONNECTION, taking every other call on it down too, and
    // the throw is asynchronous so the try/catch here never saw it.
    //
    // Measured on a default client/server pair, one connection:
    //   before: 4 of 40 sequential unary calls, then "Connection error:
    //           Connection is being forcefully terminated"
    //   after : 40 of 40, and 8 of 8 concurrent rounds
    //
    // A stream that has NOT been half-closed yet is one the caller abandoned
    // mid-request; RST_STREAM is the legal way to drop that, and terminate()
    // is what resetStream already uses.
    final stream = _activeStreams.remove(streamId);
    if (stream != null && !_halfClosedLocal.contains(streamId)) {
      try {
        stream.terminate();
        _logger?.internal('RST_STREAM для незавершённого stream $streamId');
      } catch (e) {
        _logger?.internal('Не удалось сбросить stream $streamId: $e');
      }
    }

    // Отменяем подписку на сообщения
    final subscription = _streamSubscriptions.remove(streamId);
    subscription?.cancel();

    // Удаляем парсер и tracking для этого stream
    _streamParsers.remove(streamId);
    _initialHeadersReceived.remove(streamId);
    _halfClosedLocal.remove(streamId);
    _reservedStreams.remove(streamId);
    _statusReceived.remove(streamId);

    return true;
  }

  @override
  Future<void> sendMetadata(
    int streamId,
    RpcMetadata metadata, {
    bool endStream = false,
  }) async {
    _ensureUsable();

    // Получаем путь метода из метаданных
    final methodPath = metadata.methodPath ?? '/Unknown/Unknown';

    _logger?.internal(
      'Отправка метаданных для stream $streamId: $methodPath (endStream: $endStream)',
    );

    // Конвертируем RPC метаданные в HTTP/2 headers
    final headers = rpcMetadataToHttp2RequestHeaders(
      metadata,
      method: 'POST',
      path: methodPath,
      scheme: _scheme,
      authority: _host,
    );

    // Создаем HTTP/2 stream.
    //
    // A connection that is gone must be reported as UNAVAILABLE, not as
    // package:http2's raw StateError. GOAWAY is the routine case, not an
    // exotic one: every load balancer drains with it, and every gRPC server
    // with a max-connection-age sends it on a schedule.
    //
    // The bug this fixes is an inconsistency inside this one transport. The
    // same underlying condition -- the peer's connection is gone -- produced
    // two different answers:
    //
    //   connection dies MID-call  -> RpcStatusException(14) "No response
    //                                received" (caller_pipeline), retryable
    //   connection dead, NEW call -> StateError "The http/2 connection is no
    //                                longer active", NOT retryable
    //
    // and only one of them is usable. RpcRetryInterceptor's default retries
    // UNAVAILABLE and RESOURCE_EXHAUSTED, and its doc states the intent
    // outright: "a lost connection becomes UNAVAILABLE". Measured against a
    // raw package:http2 server that answered one call and then sent GOAWAY,
    // with maxAttempts: 3 and attempts counted at the transport:
    //
    //   before: 1 attempt   (StateError is not a status, so not classifiable)
    //   after : 3 attempts
    //
    // Same defect shape as e4756025, where non-200 statuses collapsing to
    // INTERNAL made 502/503/504 permanently non-retryable.
    //
    // This makes the failure CLASSIFIABLE; it does not by itself make a retry
    // succeed on a dead connection -- that needs reconnect(), exactly as it
    // already does for the mid-call UNAVAILABLE above. Both checks are here
    // because isOpen can go false between the test and the call.
    if (!_connection.isOpen) {
      // `ClientTransportConnection.isOpen` is
      //   !isFinishing && !isTerminated && canOpenStream
      // so it folds a HEALTHY connection that is merely at the peer's
      // MAX_CONCURRENT_STREAMS (canOpenStream == false) together with a dead
      // one. Reporting the first as "the peer closed it or sent GOAWAY;
      // reconnect" is wrong three ways: the peer is alive, it sent no GOAWAY,
      // and reconnecting drops every in-flight call instead of waiting for a
      // slot. Measured against a raw server advertising concurrentStreamLimit=1
      // and holding the one stream open, the second call got exactly that
      // UNAVAILABLE-GOAWAY-reconnect message.
      //
      // canOpenStream can only be false while streams are in flight
      // (activeStreams < limit, limit >= 1), so our own active-stream count
      // separates the cases: not-open WITH active streams is saturation,
      // not-open with none is a finishing/terminated connection.
      // GOAWAY outranks the saturation heuristic below, and must: a draining
      // connection ALSO has streams in flight, so without this it was reported
      // as "at MAX_CONCURRENT_STREAMS; the connection is healthy" for the whole
      // drain -- advice to wait for a slot on a connection that is shutting
      // down. Round 76 called that case transient and self-correcting, which
      // held for a connection that was DYING (it converges in ~200ms) but not
      // for a graceful drain, which can last as long as the server's budget.
      //
      // Measured against this package's own drained shutdown:
      //   before : RpcStatusException(8) "at the server's MAX_CONCURRENT_STREAMS
      //            limit ... the connection is healthy"
      //   after  : RpcStatusException(14) "sent GOAWAY ... reconnect"
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

    _logger?.internal(
      'HTTP/2 stream создан: $streamId (активных: ${_activeStreams.length})',
    );

    // Настраиваем обработку входящих сообщений
    _setupStreamListener(streamId, stream, methodPath);

    _logger?.internal('Метаданные отправлены для stream $streamId');
  }

  @override
  Future<bool> resetStream(int streamId, {String? reason}) async {
    final stream = _activeStreams.remove(streamId);
    if (stream == null) return false;

    // RST_STREAM is the only legal way to abort a stream we have already
    // half-closed, which is exactly when cancellation arrives. Sending the
    // cancellation metadata frame instead throws "Open state expected (was:
    // HalfClosedLocal)" asynchronously out of the http2 stream handler.
    _logger?.internal(
      'Сброс stream $streamId через RST_STREAM${reason != null ? ': $reason' : ''}',
    );

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
    final controller = _streamControllers.remove(streamId);
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

    _logger?.internal(
      'Отправка данных для stream $streamId: ${data.length} байт (endStream: $endStream)',
    );

    assert(
      isGrpcFrame(data),
      'IRpcTransport.sendMessage ожидает gRPC frame с 5-байтовым префиксом',
    );

    if (_halfClosedLocal.contains(streamId)) {
      // Already half-closed: another DATA frame is a connection error.
      _logger?.warning(
        'Отброшена отправка на уже завершённый stream $streamId',
      );
      return;
    }

    // Отправляем данные через HTTP/2 как уже сформированный gRPC frame
    stream.sendData(data, endStream: endStream);
    if (endStream) _halfClosedLocal.add(streamId);

    _logger?.internal('Данные отправлены для stream $streamId');
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
      _logger?.internal('Stream $streamId уже завершён, повтор не нужен');
      return;
    }

    _logger?.internal('Завершение отправки для stream $streamId');

    // Отправляем END_STREAM
    stream.sendData(Uint8List(0), endStream: true);
    _halfClosedLocal.add(streamId);

    _logger?.internal('Отправка завершена для stream $streamId');
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

  /// Настраивает обработчик входящих сообщений для HTTP/2 stream
  void _setupStreamListener(
    int streamId,
    http2.ClientTransportStream stream,
    String methodPath,
  ) {
    _logger?.internal('Настройка обработчика для stream $streamId');

    final subscription = stream.incomingMessages.listen(
      (http2.StreamMessage message) {
        _handleIncomingMessage(streamId, message, methodPath);
      },
      onError: (error, stackTrace) {
        _logger?.error(
          'Ошибка в stream $streamId',
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
        _logger?.internal('Stream $streamId завершен');

        if (_statusReceived.contains(streamId)) {
          // Отправляем сообщение о завершении потока
          _emit(RpcTransportMessage(streamId: streamId, isEndOfStream: true));
        } else {
          // No trailers and no Trailers-Only status: the response was cut off.
          // Reporting a clean end here handed the consumer partial data as if
          // it were complete -- a server stream truncated by a dead peer looked
          // exactly like one that finished.
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

        // Очищаем ресурсы
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

  /// Обрабатывает входящее сообщение от HTTP/2 stream
  void _handleIncomingMessage(
    int streamId,
    http2.StreamMessage message,
    String methodPath,
  ) {
    // Убираем избыточное логирование - оставляем только в конкретных обработчиках

    try {
      if (message is http2.HeadersStreamMessage) {
        // Обрабатываем входящие headers (метаданные)
        _handleHeadersMessage(streamId, message, methodPath);
      } else if (message is http2.DataStreamMessage) {
        // Обрабатываем входящие данные
        _handleDataMessage(streamId, message, methodPath);
      }
    } catch (e, stackTrace) {
      _logger?.error(
        'Ошибка при обработке сообщения stream $streamId',
        error: e,
        stackTrace: stackTrace,
      );

      _emitStreamError(streamId, e, stackTrace);
    }
  }

  /// Обрабатывает входящие HTTP/2 headers (initial response or trailers).
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

    // Конвертируем HTTP/2 headers в RPC метаданные (pseudo-headers отфильтрованы)
    final metadata = http2HeadersToRpcMetadata(message.headers);
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

    // Создаем транспортное сообщение
    final transportMessage = RpcTransportMessage(
      streamId: streamId,
      metadata: metadata,
      isEndOfStream: message.endStream,
      methodPath: methodPath,
    );

    _emit(transportMessage);
  }

  /// Обрабатывает входящие HTTP/2 данные
  void _handleDataMessage(
    int streamId,
    http2.DataStreamMessage message,
    String methodPath,
  ) {
    try {
      // Получаем или создаем парсер для этого stream
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

      // Распаковываем gRPC frame(s) используя RpcMessageParser
      final bytes = message.bytes is Uint8List
          ? message.bytes as Uint8List
          : Uint8List.fromList(message.bytes);
      final messages = parser(bytes);

      // Отправляем каждое сообщение отдельно.
      // END_STREAM применяется только к действительно последнему сообщению
      // батча — сравнение по индексу, а не по значению (Uint8List сравнивается
      // по идентичности, что ломается при повторе одной и той же ссылки).
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

      _logger?.internal(
        'Обработано ${messages.length} сообщений для stream $streamId',
      );
    } catch (e, stackTrace) {
      _logger?.error(
        'Ошибка при распаковке gRPC данных для stream $streamId',
        error: e,
        stackTrace: stackTrace,
      );

      _emitStreamError(streamId, e, stackTrace);
    }
  }

  @override
  Stream<RpcTransportMessage> get incomingMessages => _messageController.stream;

  @override
  Stream<RpcTransportMessage> getMessagesForStream(int streamId) {
    final existing = _streamControllers[streamId];
    if (existing != null) return existing.stream;
    final ctl = StreamController<RpcTransportMessage>(
      onCancel: () => _streamControllers.remove(streamId),
      // Demand hop. RpcChannelTransport meters this stream and withholds
      // credit when its consumer stops; on HTTP/2 the equivalent lever is the
      // h2 window, which only closes if we stop READING. Without these two
      // lines package:http2 kept draining the socket and issuing WINDOW_UPDATE
      // no matter what the application did, so a paused client never slowed the
      // server down: measured with a server-stream handler and a client that
      // paused after 5 items, the handler produced 33906 more (132.4 MiB) in 4s
      // and was still climbing, against 1023 (4.0 MiB, flat) over websocket.
      onPause: () => _streamSubscriptions[streamId]?.pause(),
      onResume: () => _streamSubscriptions[streamId]?.resume(),
    );
    _streamControllers[streamId] = ctl;
    return ctl.stream;
  }

  /// Routes an incoming message to the shared broadcast and to the stream's
  /// dedicated controller, closing the latter on end-of-stream.
  void _emit(RpcTransportMessage message) {
    if (!_messageController.isClosed) _messageController.add(message);
    final ctl = _streamControllers[message.streamId];
    if (ctl != null && !ctl.isClosed) ctl.add(message);
    if (message.isEndOfStream) {
      final ended = _streamControllers.remove(message.streamId);
      if (ended != null && !ended.isClosed) unawaited(ended.close());
    }
  }

  /// Routes a stream-scoped error: raw on the dedicated controller, enveloped
  /// on the broadcast (so it does not leak onto unrelated streams there).
  void _emitStreamError(int streamId, Object error, [StackTrace? stackTrace]) {
    // A stream we reset on purpose reports the abort back to us. Surfacing it
    // would tell a consumer that deliberately cancelled that its own
    // cancellation was a transport failure.
    if (_resetStreams.contains(streamId)) {
      _logger?.internal(
        'Подавлена ошибка для сброшенного stream $streamId: $error',
      );
      return;
    }
    final ctl = _streamControllers[streamId];
    if (ctl != null && !ctl.isClosed) ctl.addError(error, stackTrace);
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

    _logger?.info('Попытка переподключения HTTP/2 клиента к $_host:$_port');

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
        _logger?.warning('Ошибка при отмене подписки: $e');
      }
    }
    _streamSubscriptions.clear();
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
      _nextStreamId = 1;
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
      _logger?.info('HTTP/2 клиент успешно переподключен');
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
        'Не удалось переподключить HTTP/2 клиент',
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

    _logger?.info('Закрытие HTTP/2 транспорта');
    _isClosed = true;
    // Stop probing before anything is torn down: a ping issued against a
    // connection this method is about to terminate would fail and re-run the
    // keepalive's own teardown path on an already-closing transport.
    _keepalive?.cancel();
    _keepalive = null;

    // Даем серверу время на завершение обработки активных потоков
    if (_activeStreams.isNotEmpty) {
      _logger?.internal(
        'Ожидание завершения ${_activeStreams.length} активных потоков',
      );
      await Future.delayed(Duration(milliseconds: 50));
    }

    // Abort EVERY remaining stream, half-closed ones included.
    //
    // This used to skip streams already half-closed locally, which is every
    // ordinary unary call (they send endStream: true with the request). Those
    // streams were left open on the wire -- and then, a few lines below, their
    // subscriptions were cancelled and their controllers closed, so no response
    // could ever reach the caller. `finish()` at the end of this method then
    // waited for exactly those streams to complete.
    //
    // So close() blocked for up to the graceful budget on work whose answer it
    // had already made undeliverable. Measured against the websocket sibling
    // running the identical scenario (2s handler, close() 300ms in):
    //
    //     websocket : close() 5 ms,    call UNAVAILABLE at 314 ms
    //     http2     : close() 1734 ms, call UNAVAILABLE at 2043 ms
    //
    // and decisively, with a 600ms handler so the response lands well INSIDE
    // the wait: close() took 339ms, the response arrived -- and the call still
    // failed UNAVAILABLE at 648ms. The wait cannot rescue a call; it only
    // delays shutdown.
    //
    // RST_STREAM is legal on a half-closed stream (it is how `resetStream`
    // cancels one, and the only legal way to abort after END_STREAM). The rule
    // the old filter came from is about DATA, not RST: never send DATA on a
    // stream whose request direction is finished.
    final streamsToClose = _activeStreams.values.toList();
    for (final stream in streamsToClose) {
      try {
        stream.terminate();
        _logger?.internal('RST_STREAM для stream ${stream.id} при закрытии');
      } catch (e) {
        _logger?.warning('Ошибка при закрытии stream ${stream.id}: $e');
        // В крайнем случае используем terminate
        try {
          stream.terminate();
        } catch (e2) {
          _logger?.warning('Ошибка при terminate stream ${stream.id}: $e2');
        }
      }
    }
    _activeStreams.clear();

    // Отменяем все подписки (копируем список)
    final subscriptionsToCancel = List.from(_streamSubscriptions.values);
    for (final subscription in subscriptionsToCancel) {
      try {
        await subscription.cancel();
      } catch (e) {
        _logger?.warning('Ошибка при отмене подписки: $e');
      }
    }
    _streamSubscriptions.clear();

    // Очищаем парсеры и tracking
    _streamParsers.clear();
    _initialHeadersReceived.clear();
    _halfClosedLocal.clear();
    _reservedStreams.clear();
    _statusReceived.clear();

    // Закрываем per-stream контроллеры
    for (final ctl in _streamControllers.values) {
      if (!ctl.isClosed) unawaited(ctl.close());
    }
    _streamControllers.clear();

    // Закрываем контроллер сообщений
    if (!_messageController.isClosed) {
      try {
        await _messageController.close();
      } catch (e) {
        _logger?.warning('Ошибка при закрытии контроллера сообщений: $e');
      }
    }

    // Закрываем HTTP/2 соединение.
    //
    // BOUNDED, then forceful. `finish()` is the graceful HTTP/2 shutdown: it
    // sends GOAWAY and waits for open streams to drain. Over a HALF-OPEN path
    // the peer never drains anything, so that await never completes and
    // close() hangs forever. Measured with one call in flight:
    //
    //   live path : close() returned in 104 ms
    //   half-open : close() NEVER returned (still pending at 20.4 s)
    //
    // The in-flight stream is the load-bearing condition -- with none open,
    // finish() returns promptly even on a dead path, which is why a first
    // probe without one wrongly reported no hang.
    //
    // Timing out alone is not enough: Future.timeout abandons the await, not
    // the work, so the connection would stay alive and unreferenced. terminate()
    // is what actually releases it, and is the right primitive on a dead
    // connection anyway -- finish() on one throws from package:http2 into the
    // root zone.
    try {
      await _connection.finish().timeout(_gracefulCloseTimeout);
    } catch (e) {
      _logger?.warning(
        'Graceful HTTP/2 shutdown did not complete ($e); terminating',
      );
      try {
        _connection.terminate();
      } catch (e2) {
        _logger?.warning('Ошибка при закрытии HTTP/2 соединения: $e2');
      }
    }

    _logger?.info('HTTP/2 транспорт закрыт');
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
