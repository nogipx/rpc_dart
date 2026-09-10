// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';

import 'package:http2/http2.dart' as http2;
import 'package:rpc_dart/rpc_dart.dart';
import 'package:universal_io/io.dart';

import 'http2_header_block_guard.dart';
import 'rpc_http2_common.dart';
import 'rpc_http2_responder_transport.dart';

/// HTTP/2 RPC server.
///
/// Binds the listening socket and wires up a transport per connection, creating
/// a separate [RpcResponderEndpoint] for each one.
class RpcHttp2Server implements IRpcServer {
  final String _host;
  final int _port;
  final RpcSecurityPolicy _securityPolicy;
  final SecurityContext? _securityContext;
  final LogScope? _logger;
  final LogController? _logController;
  final void Function(RpcResponderEndpoint endpoint)? _onEndpointCreated;
  final void Function(Object error, StackTrace? stackTrace)? _onConnectionError;
  final void Function(Socket socket)? _onConnectionOpened;
  final void Function(Socket socket)? _onConnectionClosed;
  final IRpcTransport Function(IRpcTransport inner, Socket socket)?
  _transportWrapper;

  // Plaintext (h2c) listener. Mutually exclusive with [_secureServerSocket].
  ServerSocket? _serverSocket;
  // TLS (h2) listener. Used when a SecurityContext is provided.
  SecureServerSocket? _secureServerSocket;
  bool _isRunning = false;

  /// Whether the server is serving over TLS (`true`) or plaintext h2c (`false`).
  bool get isSecure => _securityContext != null;
  final List<StreamSubscription> _subscriptions = [];
  final List<RpcResponderEndpoint> _endpoints = [];

  /// The HTTP/2 connection behind each endpoint.
  ///
  /// Kept only so a graceful [stop] can send GOAWAY: the endpoint abstraction
  /// has no notion of "stop accepting new streams on this connection", and that
  /// signal is the difference between a drain that converges and one that runs
  /// out its budget. Entries are removed in [_releaseEndpoint], so this tracks
  /// [_endpoints] exactly and cannot outlive it.
  final Map<RpcResponderEndpoint, http2.ServerTransportConnection>
  _connections = {};

  /// Creates an HTTP/2 RPC server.
  ///
  /// [onEndpointCreated] fires for each new connection's endpoint, which is
  /// where an application registers its contracts. [onConnectionError],
  /// [onConnectionOpened] and [onConnectionClosed] are observability hooks.
  ///
  /// [securityPolicy] bounds per-stream message size, buffered bytes, and the
  /// number of concurrent active streams per connection. Forwarded to every
  /// [RpcHttp2ResponderTransport]. Defaults to `const RpcSecurityPolicy()` so
  /// the built-in limits are enforced.
  ///
  /// [securityContext], when non-null, binds a TLS socket ([SecureServerSocket])
  /// advertising ALPN `h2` instead of a plaintext ([ServerSocket]) `h2c` one.
  /// Provide a certificate chain and private key to serve HTTP/2 over TLS.
  ///
  /// [pingInterval] and [pingTimeout] configure PING keepalive; see the field
  /// docs, which explain why the default is on. [prefaceTimeout] bounds an
  /// accepted socket that never speaks HTTP/2.
  RpcHttp2Server({
    String host = 'localhost',
    required int port,
    RpcSecurityPolicy securityPolicy = const RpcSecurityPolicy(),
    SecurityContext? securityContext,
    LogScope? logger,
    LogController? logController,
    void Function(RpcResponderEndpoint endpoint)? onEndpointCreated,
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
       _securityPolicy = securityPolicy,
       _securityContext = securityContext,
       _logger = logger?.child('Http2Server'),
       _logController = logController,
       _onEndpointCreated = onEndpointCreated,
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
  /// — the transport, the endpoint, and [_onEndpointCreated], where the
  /// application registers its contracts — is built before the peer has sent a
  /// byte. Every other limit this server has is PER CONNECTION, so
  /// `maxActiveStreams`, `maxConcurrentHandlers`, `halfOpenStreamTimeout` and
  /// the pre-method budget are all downstream of a peer that has not opened a
  /// stream. Without this deadline nothing counts connections at all, and a TCP
  /// SYN buys an endpoint plus a run of the application's callback.
  ///
  /// **What it is and is not for.** It bounds traffic that never speaks HTTP/2
  /// at all: port scanners, TLS probes, misdirected HTTP/1.1 clients, a stuck
  /// load balancer. It is NOT a defence against a determined attacker, who
  /// simply sends the 24 preface bytes — from that point the connection is a
  /// conforming idle client and [_pingInterval] is the mechanism that reclaims
  /// it. Two stages, two mechanisms; this one is the cheap half, and it is the
  /// half that is on by default.
  ///
  /// 30s is three orders of magnitude of slack: a conforming client sends the
  /// preface within one RTT, and under TLS the socket is only handed here after
  /// the handshake. **A client that opens the TCP connection eagerly and speaks
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
    RpcSecurityPolicy securityPolicy = const RpcSecurityPolicy(),
    SecurityContext? securityContext,
    LogScope? logger,
  }) {
    return RpcHttp2Server(
      host: host,
      port: port,
      securityPolicy: securityPolicy,
      securityContext: securityContext,
      logger: logger,
      onEndpointCreated: (endpoint) {
        logger?.debug(
          'Registering ${contracts.length} contract(s) on a new endpoint',
        );
        for (final contract in contracts) {
          endpoint.registerServiceContract(contract);
          logger?.debug('Registered contract: ${contract.serviceName}');
        }
      },
      onConnectionError: (error, stackTrace) {
        logger?.error(
          'HTTP/2 connection error',
          error: error,
          stackTrace: stackTrace,
        );
      },
    );
  }

  /// The host this server is bound to.
  String get host => _host;

  /// The port this server is bound to.
  ///
  /// Returns the OS-assigned port once bound when constructed with port `0`;
  /// otherwise the requested port.
  int get port => _serverSocket?.port ?? _secureServerSocket?.port ?? _port;

  /// The live endpoints, one per connection.
  @override
  List<RpcResponderEndpoint> get endpoints => List.unmodifiable(_endpoints);

  /// Waits, up to [budget], for in-flight calls to finish.
  ///
  /// Accepting has already stopped by the time this runs, but an EXISTING
  /// connection can still open new streams — so the drain begins by sending
  /// GOAWAY on every live connection. That is the HTTP/2 signal for "no new
  /// streams here", and it is what makes a gRPC graceful shutdown CONVERGE
  /// rather than merely expire: without it a call issued after shutdown began
  /// is still accepted and served, extending shutdown by work that arrived
  /// after it started.
  ///
  /// GOAWAY does NOT cut the calls already running: it carries the last stream
  /// id the peer may assume was processed, so streams below it finish normally.
  /// That is exactly the drain semantics wanted here.
  ///
  /// The budget still applies. A peer can ignore GOAWAY, and a handler can
  /// simply run long, so shutdown stays bounded either way.
  ///
  /// `activeResponders` counts live responder streams. A handler that outlives
  /// its stream is not counted — the same caveat gRPC's own drain carries, and
  /// the reason [maxActiveStreams] bounds stream state rather than handler
  /// execution.
  Future<void> _drain(Duration budget) async {
    // Send GOAWAY first, even if nothing is in flight: a peer that is about to
    // call deserves the signal, and finish() is what delivers it.
    //
    // Fired, not awaited, and individually guarded. `finish()` completes only
    // once the peer's streams drain, so awaiting it here would reproduce the
    // very hang the caller's close() was fixed for -- a dead peer never
    // finishes. The poll below is what bounds this, and the forceful close
    // after it is what releases anything still held.
    for (final connection in List.of(_connections.values)) {
      unawaited(
        Future<void>.sync(connection.finish).catchError((Object error) {
          _logger?.internal(
            'GOAWAY on a connection that was already gone: $error',
          );
        }),
      );
    }

    return drainUntilIdle(
      pending: _inFlightCalls,
      budget: budget,
      logger: _logger,
    );
  }

  /// Live responder streams across every endpoint this server owns.
  int _inFlightCalls() {
    var total = 0;
    for (final endpoint in _endpoints) {
      final metrics = endpoint.collectEndpointMetrics();
      total += (metrics['activeResponders'] as int?) ?? 0;
    }
    return total;
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
    final interval = _pingInterval;
    if (interval == null) return null;
    final timeout = _pingTimeout ?? interval;

    var inFlight = false;
    return Timer.periodic(interval, (timer) async {
      // One ping at a time: a slow-but-alive peer must not accumulate probes,
      // and a stalled one would otherwise start a new ping every interval.
      if (inFlight) return;
      inFlight = true;
      try {
        await connection.ping().timeout(timeout);
      } catch (error) {
        timer.cancel();
        _logger?.warning(
          'HTTP/2 keepalive failed for $clientAddress ($error); '
          'closing a connection whose peer stopped answering',
        );
        _notify(
          'onConnectionError',
          () => _onConnectionError?.call(
            StateError(
              'HTTP/2 keepalive: no PING ACK from $clientAddress within '
              '$timeout; the connection is half-open',
            ),
            StackTrace.current,
          ),
        );
        // Destroy, not finish: this fires socket.done, which runs the release
        // wiring that closes the endpoint and disposes its contracts.
        socket.destroy();
        return;
      } finally {
        inFlight = false;
      }
    });
  }

  /// Drops a disconnected connection's endpoint and CLOSES it.
  ///
  /// Removing it from [_endpoints] is not enough. An endpoint dropped without
  /// close() never cancels its transport subscription, never tears down its
  /// still-open responder streams, and never calls `dispose()` on its registered
  /// contracts — so whatever a contract holds (database handles, files,
  /// subscriptions) stays held for the life of the process: one leak per client
  /// disconnect.
  void _releaseEndpoint(RpcResponderEndpoint endpoint, Socket socket) {
    _endpoints.remove(endpoint);
    _connections.remove(endpoint);
    unawaited(
      endpoint.close().catchError((Object error) {
        _logger?.warning('Error closing an endpoint on disconnect: $error');
      }),
    );
    _notify('onConnectionClosed', () => _onConnectionClosed?.call(socket));
  }

  /// Invokes an observability callback without letting it take the process out.
  ///
  /// These callbacks run on DETACHED paths -- [_handleConnection] off the
  /// server socket's listen, [_releaseEndpoint] off `socket.done`'s
  /// then/catchError -- so a throw has no handler above it and reaches the root
  /// zone, where an unhandled async error kills the isolate.
  ///
  /// `onConnectionOpened` is unconditionally fatal without this, sitting outside
  /// the try below. `onConnectionClosed` is conditionally so: a throw on the
  /// graceful `.then` path is absorbed by the `.catchError` after it, but a
  /// throw on the `.catchError` path has nothing after it and escapes.
  ///
  /// Reaching this needs no misuse. A callback that reads `socket.remotePort` on
  /// close throws `OS Error 22` by itself, because the peer is already gone.
  ///
  /// Deliberately NOT applied to [_onEndpointCreated]: that one registers the
  /// contracts, so if it fails the connection is useless. The surrounding
  /// try/catch already reports it and destroys the socket, which is the right
  /// outcome -- swallowing it would start an endpoint that serves nothing.
  void _notify(String what, void Function() body) {
    try {
      body();
    } catch (error, stackTrace) {
      _logger?.error(
        'User callback $what threw',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  @override
  bool get isRunning => _isRunning;

  /// Binds the listening socket and starts accepting connections.
  @override
  Future<void> start() async {
    if (_isRunning) {
      _logger?.warning('HTTP/2 server is already running');
      return;
    }

    final scheme = isSecure ? 'h2 (TLS)' : 'h2c (plaintext)';
    _logger?.info('Starting HTTP/2 server ($scheme) on $_host:$_port');

    try {
      final Stream<Socket> connections;
      if (_securityContext != null) {
        // Advertise 'h2' for ALPN -- but do NOT treat it as a filter, because
        // it is not one here. Measured against a bare SecureServerSocket given
        // the same `supportedProtocols` as a control, the handshake completes
        // whatever the client offers (h2, http/1.1, or no ALPN at all) and the
        // server-side selectedProtocol comes back null. That is the platform's
        // TLS/ALPN behaviour, not this server's.
        //
        // Two consequences before relying on it:
        //  - No client is rejected for its protocol list. A browser, a health
        //    checker or a scanner completes the handshake and is then handed to
        //    the h2 parser, which is where it fails instead. ALPN is not an
        //    access control here.
        //  - RFC 7540 requires ALPN for h2 over TLS, so a STRICT gRPC client may
        //    refuse to proceed without a negotiated 'h2'. Lenient clients
        //    (grpcurl) interoperate fine, but that is the client forgiving,
        //    not a negotiated protocol.
        _secureServerSocket = await SecureServerSocket.bind(
          _host,
          _port,
          _securityContext,
          supportedProtocols: const ['h2'],
        );
        connections = _secureServerSocket!;
      } else {
        _serverSocket = await ServerSocket.bind(_host, _port);
        connections = _serverSocket!;
      }
      _isRunning = true;

      _logger?.info('HTTP/2 server listening ($scheme) on $_host:$port');

      final subscription = connections.listen(
        _handleConnection,
        onError: (error, stackTrace) {
          _logger?.error(
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
      _logger?.error(
        'Failed to start the HTTP/2 server',
        error: e,
        stackTrace: stackTrace,
      );
      _isRunning = false;
      rethrow;
    }
  }

  /// Stops the server, optionally letting in-flight calls finish first.
  @override
  Future<void> stop({Duration? drainTimeout}) async {
    if (!_isRunning) return;

    _logger?.info('Stopping the HTTP/2 server');
    _isRunning = false;

    // Stop ACCEPTING before any drain: draining while still accepting is not a
    // shutdown.
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    _subscriptions.clear();

    if (drainTimeout != null) await _drain(drainTimeout);

    // Iterate over a SNAPSHOT: closing an endpoint can trigger socket.done,
    // whose handler removes the endpoint from _endpoints, mutating the list
    // mid-iteration ("Concurrent modification during iteration").
    final endpointsToClose = List.of(_endpoints);
    _endpoints.clear();
    // Cleared alongside _endpoints: this map is only ever a view onto them, and
    // leaving entries here would pin dead connections for the server's lifetime.
    _connections.clear();
    for (final endpoint in endpointsToClose) {
      try {
        await endpoint.close();
      } catch (e) {
        _logger?.warning('Error closing an endpoint: $e');
      }
    }

    await _serverSocket?.close();
    _serverSocket = null;
    await _secureServerSocket?.close();
    _secureServerSocket = null;

    _logger?.info('HTTP/2 server stopped');
  }

  /// `maxActiveStreams` as an HTTP/2 SETTINGS value, clamped to what the field
  /// can actually carry.
  ///
  /// SETTINGS_MAX_CONCURRENT_STREAMS is a uint32 and [RpcSecurityPolicy] has no
  /// assertions, so the policy field can hold anything an operator types — and
  /// unclamped, both ends of the range go ON THE WIRE inverted. A negative limit
  /// wraps to 4294967295, announcing "unlimited" while the pipeline refuses
  /// every stream; anything at or above 2^32 truncates to 0, announcing "open
  /// nothing" while the server would happily serve billions.
  ///
  /// Clamping keeps the invariant that matters -- never announce MORE than will
  /// be honoured -- at both ends. A non-positive limit announces 0, which is
  /// exactly what "refuse everything" looks like on the wire; an over-large one
  /// announces the maximum representable, HTTP/2's way of saying "no limit",
  /// which is still less than what the pipeline would allow.
  ///
  /// Validating the field in `RpcSecurityPolicy` itself would be the other half
  /// of this, and it is a core semantics decision (is `0` a legitimate way to
  /// say "accept nothing"?), so it is left to the owner.
  int get _advertisedStreamLimit =>
      _securityPolicy.maxActiveStreams.clamp(0, 0xFFFFFFFF);

  /// Builds the transport, endpoint and lifecycle wiring for one connection.
  void _handleConnection(Socket socket) {
    final clientAddress = '${socket.remoteAddress}:${socket.remotePort}';
    _logger?.debug('New HTTP/2 connection from $clientAddress');

    // See disableNagle: an RPC's write pattern is the one Nagle penalises, and
    // every socket this server accepted had it enabled.
    disableNagle(
      socket,
      logger: _logger,
      what: 'connection from $clientAddress',
    );

    _notify('onConnectionOpened', () => _onConnectionOpened?.call(socket));

    // See the assignment below: without it a throwing user callback leaves one
    // permanent leak per failed connection, holding the application's
    // contracts. A throwing onEndpointCreated is ordinary rather than exotic,
    // because that callback is where those contracts get registered.
    RpcResponderEndpoint? created;
    // Armed before anything is built, cancelled by the preface below and by the
    // release wiring. See [_prefaceTimeout]: without it a TCP SYN buys an
    // endpoint and a run of the application's callback, held for as long as the
    // peer keeps the socket open.
    Timer? prefaceDeadline;

    try {
      // The incoming byte stream is passed through a header-block guard before
      // package:http2 sees it: that library concatenates a HEADERS frame and
      // its CONTINUATION frames with no bound (and O(N^2) recopy), so a peer
      // that opens a header block and never ends it floods the server's event
      // loop below every rpc_dart limit. See http2_header_block_guard.dart.
      // Outbound is the raw socket; only the read side is guarded.
      final guardedIncoming = guardHttp2HeaderBlock(
        socket,
        maxHeaderBlockBytes: _securityPolicy.maxMetadataBytes,
        onViolation: (observedBytes) {
          _logger?.warning(
            'HTTP/2 header-block cap exceeded from $clientAddress: '
            '$observedBytes bytes (max: ${_securityPolicy.maxMetadataBytes}); '
            'closing connection',
          );
          _notify(
            'onConnectionError',
            () => _onConnectionError?.call(
              StateError(
                'HTTP/2 header block exceeded ${_securityPolicy.maxMetadataBytes} '
                'bytes ($observedBytes observed): probable CONTINUATION flood',
              ),
              StackTrace.current,
            ),
          );
          socket.destroy();
        },
        onPrefaceComplete: () {
          prefaceDeadline?.cancel();
          prefaceDeadline = null;
        },
      );
      final connection = http2.ServerTransportConnection.viaStreams(
        guardedIncoming,
        socket,
        // Tell the peer the limit we will actually enforce. Pass no settings
        // and every connection advertises package:http2's default
        // MAX_CONCURRENT_STREAMS of 1000, whatever the policy says, which is
        // wrong in both directions:
        //
        // Below 1000, a conforming client paces itself by the advertisement, so
        // it opens streams it is then refused -- and RESOURCE_EXHAUSTED is
        // retryable, so it re-sends against a server that told it there was
        // room. Above 1000 the knob is DEAD, because package:http2 enforces its
        // own advertisement, so `maxActiveStreams` would mean one thing here and
        // another on websocket and isolate.
        settings: http2.ServerSettings(
          concurrentStreamLimit: _advertisedStreamLimit,
        ),
      );

      IRpcTransport transport = RpcHttp2ResponderTransport(
        connection: connection,
        policy: _securityPolicy,
        logger: _logger,
      );

      if (_transportWrapper != null) {
        final inner = transport;
        try {
          transport = _preserveCapabilities(
            inner,
            _transportWrapper(inner, socket),
          );
        } catch (error, stackTrace) {
          _logger?.error(
            'The transport wrapper threw',
            error: error,
            stackTrace: stackTrace,
          );
          _notify(
            'onConnectionError',
            () => _onConnectionError?.call(error, stackTrace),
          );
          socket.destroy();
          return;
        }
      }

      final endpoint = RpcResponderEndpoint(
        transport: transport,
        debugLabel: 'Http2Endpoint-$clientAddress',
        logger: _logController,
      );

      _endpoints.add(endpoint);
      _connections[endpoint] = connection;
      // Remembered so the catch below can release it if the user callback
      // throws: the endpoint is registered here, BEFORE that callback, and the
      // `socket.done` release wiring is only installed after it.
      created = endpoint;

      // Armed here rather than at the top of the method so it can name the
      // endpoint it releases; the preface cannot have arrived yet, because
      // nothing has subscribed to the guarded stream until endpoint.start().
      final deadline = _prefaceTimeout;
      if (deadline != null) {
        prefaceDeadline = Timer(deadline, () {
          prefaceDeadline = null;
          _logger?.warning(
            'Dropping $clientAddress: no HTTP/2 connection preface within '
            '${deadline.inSeconds}s',
          );
          _releaseEndpoint(endpoint, socket);
          socket.destroy();
        });
      }

      _onEndpointCreated?.call(endpoint);
      endpoint.start();

      _logger?.debug('RPC endpoint created for $clientAddress');

      // Keepalive: the only thing that reclaims a HALF-OPEN connection. See
      // [_pingInterval]. Started only when configured, and always cancelled by
      // the release wiring below, so a closed connection stops pinging.
      final keepalive = _startKeepalive(connection, socket, clientAddress);

      socket.done
          .then((_) {
            _logger?.debug('HTTP/2 connection $clientAddress closed');
            keepalive?.cancel();
            prefaceDeadline?.cancel();
            _releaseEndpoint(endpoint, socket);
          })
          .catchError((error) {
            _logger?.warning('Error closing connection $clientAddress: $error');
            keepalive?.cancel();
            prefaceDeadline?.cancel();
            _releaseEndpoint(endpoint, socket);
          });
    } catch (e, stackTrace) {
      prefaceDeadline?.cancel();
      _logger?.error(
        'Failed to create an HTTP/2 RPC connection',
        error: e,
        stackTrace: stackTrace,
      );
      _notify(
        'onConnectionError',
        () => _onConnectionError?.call(e, stackTrace),
      );
      // Release what was already registered. _releaseEndpoint removes it,
      // closes it -- which is what disposes the contracts -- and fires
      // onConnectionClosed, balancing the onConnectionOpened above for a
      // connection now being torn down.
      final orphan = created;
      if (orphan != null) _releaseEndpoint(orphan, socket);
      socket.destroy();
    }
  }
}

/// Keeps the capability interfaces the wrapper dropped.
///
/// The endpoint layers find optional transport capabilities with `is` checks
/// and fall back to a default when the check fails -- SILENTLY. So the obvious
/// decorator (implement [IRpcTransport], forward every method) removes them:
/// the responder pipeline then reads `const RpcSecurityPolicy()` instead of the
/// policy this server was configured with, and a `maxActiveStreams` ceiling
/// simply stops existing. Nothing says so -- the wrapper compiles and every
/// call works.
///
/// A decorator that wants to CHANGE the policy declares
/// [IRpcSecurityPolicyAware] itself and is left alone; there is no other way to
/// express that intent, so a wrapper that declares nothing is an oversight
/// rather than a choice. Restoring is therefore what the author meant.
IRpcTransport _preserveCapabilities(
  IRpcTransport inner,
  IRpcTransport wrapped,
) {
  if (identical(inner, wrapped)) return wrapped;
  final needsPolicy =
      inner is IRpcSecurityPolicyAware && wrapped is! IRpcSecurityPolicyAware;
  final needsFlow =
      inner is IRpcFlowControlled && wrapped is! IRpcFlowControlled;
  if (!needsPolicy && !needsFlow) return wrapped;
  return _CapabilityPreservingTransport(inner: inner, wrapped: wrapped);
}

/// Delegates [IRpcTransport] to the user's wrapper and the capabilities to the
/// transport it wrapped. See [_preserveCapabilities].
class _CapabilityPreservingTransport
    implements IRpcTransport, IRpcSecurityPolicyAware, IRpcFlowControlled {
  _CapabilityPreservingTransport({required this.inner, required this.wrapped});

  /// The transport handed to the wrapper; the source of the capabilities.
  final IRpcTransport inner;

  /// What the wrapper returned; every call still goes through it.
  final IRpcTransport wrapped;

  // Explicit casts, not `is`-promotion: IRpcSecurityPolicyAware and
  // IRpcFlowControlled are neither subtypes nor supertypes of IRpcTransport, so
  // Dart forms no intersection type and an `is` test promotes nothing. Core
  // reads the same capabilities the same way.
  @override
  RpcSecurityPolicy get securityPolicy {
    final outer = wrapped;
    if (outer is IRpcSecurityPolicyAware) {
      return (outer as IRpcSecurityPolicyAware).securityPolicy;
    }
    final source = inner;
    if (source is IRpcSecurityPolicyAware) {
      return (source as IRpcSecurityPolicyAware).securityPolicy;
    }
    return const RpcSecurityPolicy();
  }

  /// Prefers the wrapper when it implements the capability, so a decorator that
  /// meters flow control keeps control of it.
  IRpcFlowControlled? get _flowControlled {
    final outer = wrapped;
    if (outer is IRpcFlowControlled) return outer as IRpcFlowControlled;
    final source = inner;
    if (source is IRpcFlowControlled) return source as IRpcFlowControlled;
    return null;
  }

  /// Always tells the INNER transport too, whatever the wrapper does with it.
  ///
  /// The wrapper can only ever report CONSUMPTION; the charge lives in the
  /// transport that actually sees the bytes arrive, and that transport only
  /// charges a stream it has been told is pipeline-fed. So a decorator that
  /// declares [IRpcFlowControlled] and then swallows it switches the inner
  /// accounting off entirely, and the window stops bounding anything -- exactly
  /// the shape this class exists to prevent, arriving through the very
  /// capability it forwards.
  ///
  /// Deferring on both is safe because it is a set membership: a decorator that
  /// forwards produces one entry, not two. `returnFlowCredit` is deliberately
  /// NOT doubled the same way -- a forwarding decorator would then discharge
  /// twice and the bound would vanish again, the other way round.
  ///
  /// A decorator that swallows the report now starves the budget instead of
  /// removing it, so its calls are refused at the window rather than running
  /// unbounded. That is the loud failure, which is the one to have.
  @override
  void deferFlowCredit(int streamId) {
    _flowControlled?.deferFlowCredit(streamId);
    final source = inner;
    if (source is IRpcFlowControlled) {
      (source as IRpcFlowControlled).deferFlowCredit(streamId);
    }
  }

  @override
  void returnFlowCredit(int streamId, int bytes) =>
      _flowControlled?.returnFlowCredit(streamId, bytes);

  @override
  bool get isClient => wrapped.isClient;
  @override
  bool get isClosed => wrapped.isClosed;
  @override
  bool get supportsZeroCopy => wrapped.supportsZeroCopy;
  @override
  Stream<RpcTransportMessage> get incomingMessages => wrapped.incomingMessages;
  @override
  Stream<RpcTransportMessage> getMessagesForStream(int streamId) =>
      wrapped.getMessagesForStream(streamId);
  @override
  int createStream() => wrapped.createStream();
  @override
  bool releaseStreamId(int streamId) => wrapped.releaseStreamId(streamId);
  @override
  Future<void> sendMetadata(
    int streamId,
    RpcMetadata metadata, {
    bool endStream = false,
  }) => wrapped.sendMetadata(streamId, metadata, endStream: endStream);
  @override
  Future<void> sendMessage(
    int streamId,
    Uint8List data, {
    bool endStream = false,
  }) => wrapped.sendMessage(streamId, data, endStream: endStream);
  @override
  Future<void> sendDirectObject(
    int streamId,
    Object object, {
    bool endStream = false,
  }) => wrapped.sendDirectObject(streamId, object, endStream: endStream);
  @override
  Future<void> finishSending(int streamId) => wrapped.finishSending(streamId);
  @override
  Future<RpcHealthStatus> health() => wrapped.health();
  @override
  Future<RpcHealthStatus> reconnect() => wrapped.reconnect();
  @override
  Future<void> close() => wrapped.close();
}
