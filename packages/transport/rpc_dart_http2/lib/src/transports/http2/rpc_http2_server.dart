// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';

import 'package:http2/http2.dart' as http2;
import 'package:rpc_dart/transport.dart';
import 'package:universal_io/io.dart';

import 'rpc_http2_common.dart';
import 'rpc_http2_responder_transport.dart';

/// HTTP/2 RPC server.
///
/// Binds the listening socket and wires up a transport per connection, creating
/// a separate [RpcResponderEndpoint] for each one.
class RpcHttp2Server implements IRpcServer {
  final String _host;
  final int _port;
  final RpcSecurityPolicy _policy;
  final SecurityContext? _securityContext;

  /// Set once a connection that never sent its preface has been reported.
  bool _warnedSilentPeer = false;

  final LogScope _log;
  final RpcConnectionHost _connectionHost;
  final void Function(Object error, StackTrace? stackTrace)? _onConnectionError;
  final void Function(Socket socket)? _onConnectionOpened;
  final void Function(Socket socket)? _onConnectionClosed;
  final IRpcTransport Function(IRpcTransport inner, Socket socket)?
  _transportWrapper;

  // The listener. Under TLS it accepts plain sockets and [_acceptTls] runs the
  // handshake, so the wait for it can have a deadline: a SecureServerSocket
  // finishes it before handing the socket over, and a client that connects
  // and sends nothing is held for as long as it likes.
  ServerSocket? _serverSocket;

  /// Accepted sockets still in the TLS handshake, destroyed by [stop].
  final Set<Socket> _handshaking = {};
  bool _isRunning = false;

  /// Claimed by [start] before its first await, so a concurrent second call
  /// cannot get past the guard while the bind is in flight.
  bool _starting = false;

  /// Whether the server is serving over TLS (`true`) or plaintext h2c (`false`).
  bool get isSecure => _securityContext != null;
  final List<StreamSubscription<void>> _subscriptions = [];

  /// The HTTP/2 connection behind each endpoint.
  ///
  /// Kept only so a graceful [stop] can send GOAWAY: the endpoint abstraction
  /// has no notion of "stop accepting new streams on this connection", and that
  /// signal is the difference between a drain that converges and one that runs
  /// out its budget. A connection leaves when its endpoint is released.
  final Set<http2.ServerTransportConnection> _connections = {};

  /// Creates an HTTP/2 RPC server.
  ///
  /// [mode] registers the application's contracts on each new connection's
  /// endpoint. [onConnectionError], [onConnectionOpened] and
  /// [onConnectionClosed] are observability hooks.
  ///
  /// [policy] bounds per-stream message size, buffered bytes, and the
  /// number of concurrent active streams per connection. Forwarded to every
  /// [RpcHttp2ResponderTransport]. Defaults to `const RpcSecurityPolicy()` so
  /// the built-in limits are enforced.
  ///
  /// [securityContext], when non-null, binds a TLS socket ([SecureServerSocket])
  /// advertising ALPN `h2` instead of a plaintext ([ServerSocket]) `h2c` one.
  /// Provide a certificate chain and private key to serve HTTP/2 over TLS.
  /// [start] sets the context's server-side ALPN list to `['h2']`, replacing
  /// any list already set on it.
  ///
  /// [pingInterval] and [pingTimeout] configure PING keepalive; see the field
  /// docs, which explain why the default is on. [prefaceTimeout] bounds an
  /// accepted socket that never speaks HTTP/2.
  ///
  /// [maxConnections] caps concurrent connections, those still in their TLS
  /// handshake included; one past it is closed as it is accepted. Null, the
  /// default, sets no cap.
  RpcHttp2Server({
    String host = 'localhost',
    required int port,
    required RpcResponderMode mode,
    RpcSecurityPolicy policy = const RpcSecurityPolicy(),
    SecurityContext? securityContext,
    LogScope? logger,
    LogController? logController,
    int? maxConnections,
    void Function(Object error, StackTrace? stackTrace)? onConnectionError,
    void Function(Socket socket)? onConnectionOpened,
    void Function(Socket socket)? onConnectionClosed,
    IRpcTransport Function(IRpcTransport inner, Socket socket)?
    transportWrapper,
    Duration? pingInterval = const Duration(seconds: 30),
    // NOT defaulted. Null here means "follow pingInterval", and that fallback
    // is load-bearing: giving this a concrete default made a caller passing
    // `pingInterval: 2s` wait 20s for the ACK, and
    // server_keepalive_reclaims_half_open_test went red on its own budget.
    Duration? pingTimeout,
    Duration? prefaceTimeout = const Duration(seconds: 30),
  }) : _host = host,
       _port = port,
       _policy = policy,
       _securityContext = securityContext,
       _log = logger?.child('Http2Server') ?? LogScope.noop,
       _connectionHost = RpcConnectionHost(
         mode: mode,
         maxConnections: maxConnections,
         logger: logger?.child('Http2Server'),
         logController: logController,
       ),
       _onConnectionError = onConnectionError,
       _onConnectionOpened = onConnectionOpened,
       _onConnectionClosed = onConnectionClosed,
       _transportWrapper = transportWrapper,
       _pingInterval = pingInterval,
       _pingTimeout = pingTimeout,
       _prefaceTimeout = prefaceTimeout;

  /// How long an ACCEPTED socket may go without sending the HTTP/2 connection
  /// preface before it is dropped. Null disables the deadline.
  ///
  /// [_handleConnection] is wired to the accept stream, so everything it builds
  /// — the transport, the endpoint, and the mode's register, where the
  /// application registers its contracts — is built before the peer has sent a
  /// byte. Every other limit this server has is PER CONNECTION, so
  /// `maxActiveStreams`, `maxConcurrentHandlers`, `halfOpenStreamTimeout` and
  /// the pre-method budget are all downstream of a peer that has not opened a
  /// stream. Without this deadline a TCP SYN buys an endpoint plus a run of
  /// the application's callback, held until the peer closes; `maxConnections`
  /// caps how many, not how long.
  ///
  /// **What it is and is not for.** It bounds traffic that never speaks HTTP/2
  /// at all: port scanners, TLS probes, misdirected HTTP/1.1 clients, a stuck
  /// load balancer. It is NOT a defence against a determined attacker, who
  /// simply sends the 24 preface bytes — from that point the connection is a
  /// conforming idle client and [_pingInterval] is the mechanism that reclaims
  /// it. Two stages, two mechanisms; this one is the cheap half, and it is the
  /// half that is on by default.
  ///
  /// Under TLS the same deadline first bounds the wait for the client's TLS
  /// hello: a socket that connects and sends nothing is destroyed when it
  /// passes, and the preface deadline starts once the handshake is done.
  ///
  /// 30s is three orders of magnitude of slack: a conforming client sends the
  /// preface within one RTT. **A client that opens the TCP connection eagerly and speaks
  /// HTTP/2 much later — some load balancers pre-warm this way — is dropped**;
  /// pass null to keep the old behaviour.
  final Duration? _prefaceTimeout;

  /// How often to send an HTTP/2 PING on an otherwise idle connection, and the
  /// only way this server detects a HALF-OPEN one.
  ///
  /// A NAT box, load balancer or mobile network that silently stops forwarding
  /// sends no FIN and no RST, so the server's socket still looks fine and the
  /// connection — with its endpoint, and the application's contracts on it — is
  /// held forever. A contract that is never disposed keeps whatever it owns:
  /// database handles, caches, subscriptions. A fleet of mobile clients on
  /// flaky networks accumulates them.
  ///
  /// **On by default (30s), and it is the ONLY bound on a held endpoint.**
  /// [_prefaceTimeout] deliberately does not cover this case — 24 preface bytes
  /// buy past it — so a peer that speaks HTTP/2 and then goes silent is
  /// reclaimed by nothing else.
  ///
  /// An idle connection therefore carries a PING every 30s and is dropped if no
  /// ACK arrives within [_pingTimeout]. Pass `null` to disable; raise both on a
  /// fleet where radio wake-ups matter. Too short wakes radios and wastes
  /// battery, too long leaves dead connections resident — take the shortest idle
  /// timeout on the path (load balancers commonly use 60s) and halve it, which
  /// is where 30s comes from.
  ///
  /// This is the same mechanism gRPC servers use
  /// (`GRPC_ARG_KEEPALIVE_TIME_MS`), so it is understood by foreign peers: a
  /// PING must be answered by any conforming HTTP/2 implementation.
  final Duration? _pingInterval;

  /// How long to wait for a PING ACK before treating the connection as dead.
  /// Defaults to [_pingInterval] when not given.
  final Duration? _pingTimeout;

  /// An HTTP/2 server that registers [contracts] on every endpoint it creates.
  factory RpcHttp2Server.createWithContracts({
    required int port,
    required List<RpcResponderContract> contracts,
    String host = 'localhost',
    RpcSecurityPolicy policy = const RpcSecurityPolicy(),
    SecurityContext? securityContext,
    LogScope? logger,
    LogController? logController,
    int? maxConnections,
    Duration? pingInterval = const Duration(seconds: 30),
    Duration? pingTimeout,
    Duration? prefaceTimeout = const Duration(seconds: 30),
  }) {
    return RpcHttp2Server(
      host: host,
      port: port,
      mode: RpcResponderMode.contracts(contracts),
      policy: policy,
      securityContext: securityContext,
      logger: logger,
      logController: logController,
      maxConnections: maxConnections,
      pingInterval: pingInterval,
      pingTimeout: pingTimeout,
      prefaceTimeout: prefaceTimeout,
    );
  }

  /// The host this server is bound to.
  String get host => _host;

  /// The port this server is bound to.
  ///
  /// Returns the OS-assigned port once bound when constructed with port `0`;
  /// otherwise the requested port.
  int get port => _serverSocket?.port ?? _port;

  /// The live endpoints, one per connection.
  @override
  List<RpcResponderEndpoint> get endpoints => _connectionHost.responders;

  /// Sends GOAWAY on every live connection, the start of a drain.
  ///
  /// Accepting has already stopped by the time this runs, but an EXISTING
  /// connection can still open new streams. GOAWAY is the HTTP/2 signal for
  /// "no new streams here", and it is what makes a gRPC graceful shutdown
  /// CONVERGE rather than merely expire. It does not cut the calls already
  /// running: it carries the last stream id the peer may assume was processed,
  /// so streams below it finish normally.
  ///
  /// The drain budget still applies. A peer can ignore GOAWAY, and a handler
  /// can simply run long, so shutdown stays bounded either way.
  void _sendGoaway() {
    // Fired, not awaited, and individually guarded. `finish()` completes only
    // once the peer's streams drain, and a dead peer never finishes. The drain
    // budget bounds this, and the forceful close after it releases anything
    // still held.
    for (final connection in List.of(_connections)) {
      unawaited(
        Future<void>.sync(connection.finish).catchError((Object error) {
          if (_log.isInternal) {
            _log.internal(
              'GOAWAY on a connection that was already gone: $error',
            );
          }
        }),
      );
    }
  }

  /// Starts PING keepalive for one connection, or returns null when disabled.
  ///
  /// A dead peer never answers, so `ping()` simply never completes — hence the
  /// timeout, which is what actually detects the half-open path. On failure the
  /// socket is DESTROYED rather than finished: `finish()` on a connection whose
  /// peer is gone throws from package:http2 into the root zone, and destroying
  /// the socket is what fires `socket.done` and so runs the ordinary release
  /// wiring (endpoint closed, contracts disposed, onConnectionClosed fired).
  ///
  /// Every await here is guarded. This runs on a detached timer callback, so an
  /// unhandled async error would reach the root zone and kill the isolate —
  /// the failure mode `_notify` exists for elsewhere in this class.
  Timer? _startKeepalive(
    http2.ServerTransportConnection connection,
    Socket socket,
    String clientAddress,
  ) {
    final timeout = _pingTimeout ?? _pingInterval;
    return startHttp2Keepalive(
      interval: _pingInterval,
      timeout: _pingTimeout,
      ping: connection.ping,
      // The guard this half LACKED. The release wiring on `socket.done` does
      // cancel the timer, but a stopped server with a socket still open kept
      // probing until that fired.
      isDead: () => !_isRunning,
      onDead: (error) {
        _log.warning(
          'HTTP/2 keepalive failed for $clientAddress ($error); '
          'closing a connection whose peer stopped answering',
        );
        _notify(
          'onConnectionError',
          () => _onConnectionError?.call(
            RpcStatusException(
              RpcStatus.unavailable,
              'HTTP/2 keepalive: no PING ACK from $clientAddress within '
              '$timeout; the connection is half-open',
            ),
            StackTrace.current,
          ),
        );
        // Destroy, not finish: this fires socket.done, which runs the release
        // wiring that closes the endpoint and disposes its contracts.
        socket.destroy();
      },
    );
  }

  /// Invokes an observability callback without letting it take the process out.
  ///
  /// These callbacks run on DETACHED paths, [_handleConnection] off the server
  /// socket's listen and the keepalive off a timer, so a throw has no handler
  /// above it and reaches the root zone, where an unhandled async error kills
  /// the isolate.
  ///
  /// Not applied to the mode's register: it registers the contracts, so if it
  /// fails the connection is useless. The surrounding try/catch reports it and
  /// destroys the socket.
  void _notify(String what, void Function() body) =>
      notifyWithoutDying(what, body, logger: _log);

  @override
  bool get isRunning => _isRunning;

  /// Binds the listening socket and starts accepting connections.
  ///
  /// A [stop] in flight is finished first, as on the websocket server. A
  /// restart overlapping it would leave a later [stop] returning that first
  /// stop's future while the restarted server keeps serving.
  @override
  Future<void> start() async {
    final stopping = _stopping;
    if (stopping != null) await stopping;
    // `_isRunning` alone cannot hold this: it is assigned AFTER the bind's await,
    // so two concurrent callers would both pass the guard and both bind, and
    // the loser's catch would set it false over the winner's true, leaving a
    // bound listener that `stop()` gives up on.
    //
    // The slot is therefore claimed SYNCHRONOUSLY, before anything suspends, and
    // released in the catch so a retry after "address in use" still works.
    if (_isRunning || _starting) {
      _log.warning(
        'HTTP/2 server is already ${_isRunning ? 'running' : 'starting'}',
      );
      return;
    }
    _starting = true;
    final bound = Completer<void>();
    _bind = bound.future;

    final scheme = isSecure ? 'h2 (TLS)' : 'h2c (plaintext)';
    _log.info('Starting HTTP/2 server ($scheme) on $_host:$_port');

    try {
      final Stream<Socket> connections;
      if (_securityContext != null) {
        // ALPN 'h2' is set on the context, NOT passed as `supportedProtocols`
        // to bind: given that parameter, the server selects nothing and every
        // client sees ALPN none -- which our own caller refuses. On the
        // context, a client offering h2 gets h2.
        //
        // It is not a filter. A client offering only http/1.1, or no ALPN at
        // all, still completes the handshake with nothing selected and is then
        // handed to the h2 parser, which is where it fails instead.
        _securityContext.setAlpnProtocols(const ['h2'], true);
      }
      _serverSocket = await ServerSocket.bind(_host, _port);
      connections = _serverSocket!;
      _isRunning = true;

      _log.info('HTTP/2 server listening ($scheme) on $_host:$port');

      final subscription = connections.listen(
        _accept,
        onError: (Object error, StackTrace stackTrace) {
          _log.error(
            'Server socket error',
            error: error,
            stackTrace: stackTrace,
          );
          _notify(
            'onConnectionError',
            () => _onConnectionError?.call(error, stackTrace),
          );
        },
      );

      _subscriptions.add(subscription);
    } catch (e, stackTrace) {
      _log.error(
        'Failed to start the HTTP/2 server',
        error: e,
        stackTrace: stackTrace,
      );
      _isRunning = false;
      _starting = false;
      rethrow;
    } finally {
      bound.complete();
    }
  }

  /// The bind of a [start] in progress. [stop] waits it out: before the bind
  /// lands there is nothing to stop, and the listener that lands after it was
  /// reachable by nothing.
  Future<void>? _bind;

  /// Stops the server, optionally letting in-flight calls finish first.
  ///
  /// A second [stop] while one is in flight returns that one's future, so it
  /// completes only when the server has stopped.
  @override
  Future<void> stop({Duration? drainTimeout}) =>
      _stopping ??= _stop(drainTimeout).whenComplete(() => _stopping = null);

  Future<void>? _stopping;

  Future<void> _stop(Duration? drainTimeout) async {
    final bind = _bind;
    if (!_isRunning && _starting && bind != null) await bind;
    if (!_isRunning) return;

    _log.info('Stopping the HTTP/2 server');
    _isRunning = false;
    // Or a server stopped and started again is refused by its own claim.
    _starting = false;

    // Stop ACCEPTING before any drain: draining while still accepting is not a
    // shutdown.
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    _subscriptions.clear();

    // GOAWAY first, even if nothing is in flight: a peer that is about to call
    // deserves the signal.
    if (drainTimeout != null) _sendGoaway();
    await _connectionHost.stop(drainTimeout: drainTimeout);
    _connections.clear();

    for (final socket in _handshaking) {
      socket.destroy();
    }
    _handshaking.clear();
    await _serverSocket?.close();
    _serverSocket = null;

    _log.info('HTTP/2 server stopped');
  }

  /// Waits for the client's first bytes under the preface deadline, then runs
  /// the TLS handshake and hands the secured socket to [_handleConnection].
  ///
  /// The deadline is enforced BEFORE the handshake starts, on purpose: once
  /// `SecureSocket.secureServer` has taken the socket over, destroying the
  /// original no longer closes it, so a deadline on the handshake itself
  /// abandons a socket the handshake still holds. Reading the ClientHello's
  /// first chunk here and passing it as `bufferedData` keeps the socket ours
  /// until the client has spoken. A client that sends part of a handshake and
  /// stalls is not bounded by this.
  ///
  /// A failed handshake destroys the socket and is not reported as a
  /// connection error: it is what a scanner or a plain-text client produces,
  /// and a SecureServerSocket drops those silently too.
  void _acceptTls(Socket raw) {
    // Read now: a destroyed socket throws on remoteAddress.
    final peer = '${raw.remoteAddress.address}:${raw.remotePort}';
    _handshaking.add(raw);
    Timer? deadline;
    late final StreamSubscription<List<int>> first;
    void drop(String why) {
      deadline?.cancel();
      _handshaking.remove(raw);
      unawaited(first.cancel());
      raw.destroy();
      if (_log.isDebug) {
        _log.debug('Dropping $peer before TLS: $why');
      }
    }

    first = raw.listen(
      (chunk) {
        deadline?.cancel();
        // Paused, not cancelled: secureServer takes the socket over from a
        // paused subscription, and cancelling would close its read side.
        first.pause();
        SecureSocket.secureServer(
          raw,
          _securityContext,
          bufferedData: chunk,
        ).then(
          (secure) {
            _handshaking.remove(raw);
            if (!_isRunning) {
              secure.destroy();
              return;
            }
            _handleConnection(secure);
          },
          onError: (Object error) {
            _handshaking.remove(raw);
            raw.destroy();
            if (_log.isDebug) {
              _log.debug('TLS handshake with $peer failed: $error');
            }
          },
        );
      },
      onError: (Object error) => drop('$error'),
      onDone: () => drop('closed by the peer'),
      cancelOnError: true,
    );
    final timeout = _prefaceTimeout;
    if (timeout != null) {
      deadline = Timer(timeout, () => drop('nothing sent within $timeout'));
    }
  }

  /// Admits [socket] under the connection cap, then serves it, after a TLS
  /// handshake when the server is secure.
  void _accept(Socket socket) {
    if (!_connectionHost.admit(pending: _handshaking.length)) {
      socket.destroy();
      return;
    }
    if (_securityContext == null) {
      _handleConnection(socket);
    } else {
      _acceptTls(socket);
    }
  }

  /// Builds the transport, endpoint and lifecycle wiring for one connection.
  void _handleConnection(Socket socket) {
    final clientAddress = '${socket.remoteAddress}:${socket.remotePort}';
    if (_log.isDebug) {
      _log.debug('New HTTP/2 connection from $clientAddress');
    }

    // See disableNagle: an RPC's write pattern is the one Nagle penalises, and
    // every socket this server accepted had it enabled.
    disableNagle(socket, logger: _log, what: 'connection from $clientAddress');

    _notify('onConnectionOpened', () => _onConnectionOpened?.call(socket));

    // Cancelled by the preface and by the release. See [_prefaceTimeout]:
    // without it a TCP SYN buys an endpoint and a run of the application's
    // register, held for as long as the peer keeps the socket open.
    Timer? prefaceDeadline;
    Timer? keepalive;
    var released = false;

    try {
      // ONE construction path, shared with anyone running their own accept
      // loop. `overStreams` applies the header-block guard and the advertised
      // MAX_CONCURRENT_STREAMS — the two parts of the policy that cannot be
      // attached to a connection after it exists, and which this server used to
      // be the only holder of.
      final responderTransport = RpcHttp2ResponderTransport.overStreams(
        incoming: socket,
        outgoing: socket,
        destroy: socket.destroy,
        policy: _policy,
        logger: _log,
        onHeaderBlockViolation: (observedBytes) {
          _notify(
            'onConnectionError',
            () => _onConnectionError?.call(
              RpcStatusException(
                RpcStatus.resourceExhausted,
                'HTTP/2 header block exceeded ${_policy.maxMetadataBytes} '
                'bytes ($observedBytes observed): probable CONTINUATION flood '
                'from $clientAddress',
              ),
              StackTrace.current,
            ),
          );
        },
        onPrefaceComplete: () {
          prefaceDeadline?.cancel();
          prefaceDeadline = null;
        },
      );
      final connection = responderTransport.connection;
      IRpcTransport transport = responderTransport;

      if (_transportWrapper != null) {
        final inner = transport;
        try {
          transport = _transportWrapper(inner, socket);
        } catch (error, stackTrace) {
          _log.error(
            'The transport wrapper threw',
            error: error,
            stackTrace: stackTrace,
          );
          _notify(
            'onConnectionError',
            () => _onConnectionError?.call(error, stackTrace),
          );
          // No endpoint exists yet to release, so balance onConnectionOpened
          // here.
          _notify(
            'onConnectionClosed',
            () => _onConnectionClosed?.call(socket),
          );
          socket.destroy();
          return;
        }
      }

      final endpoint = _connectionHost.serve(
        transport,
        done: socket.done.then(
          (_) {
            if (_log.isDebug) {
              _log.debug('HTTP/2 connection $clientAddress closed');
            }
          },
          onError: (Object error) {
            _log.warning('Error closing connection $clientAddress: $error');
          },
        ),
        debugLabel: 'Http2Endpoint-$clientAddress',
        onRelease: () {
          released = true;
          _connections.remove(connection);
          keepalive?.cancel();
          prefaceDeadline?.cancel();
          _onConnectionClosed?.call(socket);
        },
      );
      // Added after serve: when the register throws, serve releases the
      // endpoint and rethrows, so a failed connection never lands here.
      _connections.add(connection);

      // Armed synchronously after the endpoint started: the preface arrives
      // as a socket event, so it cannot have been read yet.
      final deadline = _prefaceTimeout;
      if (deadline != null) {
        prefaceDeadline = Timer(deadline, () {
          prefaceDeadline = null;
          // Any scanner can open sockets that say nothing: warned once.
          if (!_warnedSilentPeer) {
            _warnedSilentPeer = true;
            _log.warning(
              'Dropping $clientAddress: no HTTP/2 connection preface within '
              '${deadline.inSeconds}s',
            );
          }
          _connectionHost.release(endpoint);
          socket.destroy();
        });
      }

      if (_log.isDebug) {
        _log.debug('RPC endpoint created for $clientAddress');
      }

      // Keepalive: the only thing that reclaims a HALF-OPEN connection. See
      // [_pingInterval]. Started only when configured, and cancelled by the
      // release, so a closed connection stops pinging.
      keepalive = _startKeepalive(connection, socket, clientAddress);
    } catch (e, stackTrace) {
      prefaceDeadline?.cancel();
      _log.error(
        'Failed to create an HTTP/2 RPC connection',
        error: e,
        stackTrace: stackTrace,
      );
      _notify(
        'onConnectionError',
        () => _onConnectionError?.call(e, stackTrace),
      );
      // Balances the onConnectionOpened above, unless releasing the endpoint
      // already did.
      if (!released) {
        _notify('onConnectionClosed', () => _onConnectionClosed?.call(socket));
      }
      socket.destroy();
    }
  }
}
