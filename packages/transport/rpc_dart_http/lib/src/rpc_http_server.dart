// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:io';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;

import 'rpc_http_cors_policy.dart';
import 'rpc_http_responder_transport.dart';

/// HTTP/1.1 RPC server for use with [RpcApp.server].
///
/// Unlike WebSocket/HTTP/2 servers that create one endpoint per connection,
/// HTTP/1.1 uses a single persistent [RpcResponderEndpoint] for all requests.
/// This creates a timing problem with the framework: [buildContracts] is
/// normally called during [start], before module [onStart] hooks run, so the
/// DI container is not yet populated.
///
/// [RpcHttpServer] solves this by splitting setup into two phases:
///
/// - [start]: creates the [RpcHttpResponderTransport] but does NOT bind the
///   port and does NOT call [onEndpointCreated]. No requests are accepted yet.
///
/// - [afterModulesStart]: call this inside [RpcApp.server]'s `afterModulesStart`
///   callback, after all module [onStart] hooks have run. At that point the DI
///   container is fully populated. Creates the endpoint, calls
///   [onEndpointCreated] (interceptors + [buildContracts] are applied), then
///   binds the shelf HTTP server.
///
/// ```dart
/// RpcHttpServer? httpServer;
///
/// await RpcApp.server(
///   modules: [DatabaseModule(), UserModule()],
///   server: (onEndpoint) {
///     httpServer = RpcHttpServer(
///       host: '0.0.0.0',
///       port: 8080,
///       onEndpointCreated: onEndpoint,
///     );
///     return httpServer!;
///   },
///   afterModulesStart: (_) async => httpServer!.afterModulesStart(),
///   interceptors: [authInterceptor],
/// ).run();
/// ```
///
/// If you need shelf-level middleware (e.g. a webhook handler) mounted in
/// front of the RPC handler, pass it via [afterModulesStart]'s [preamble]
/// parameter:
///
/// ```dart
/// afterModulesStart: (container) async {
///   final webhook = container.tryGet<MyWebhookHandler>();
///   await httpServer!.afterModulesStart(preamble: webhook?.call);
/// },
/// ```
class RpcHttpServer implements IRpcServer {
  final String _host;
  final int _port;
  final RpcHttpCorsPolicy? _corsPolicy;
  final RpcSecurityPolicy? _securityPolicy;
  final Duration? _bodyReadTimeout;
  final void Function(RpcResponderEndpoint) _onEndpointCreated;
  final LogScope? _logger;
  final LogController? _logController;

  RpcHttpResponderTransport? _transport;
  RpcResponderEndpoint? _endpoint;
  HttpServer? _httpServer;
  bool _isRunning = false;

  /// Creates an HTTP/1.1 RPC server.
  ///
  /// [securityPolicy] bounds request body size, header sizes, and concurrent
  /// requests. It defaults to a non-null [RpcSecurityPolicy] so the built-in
  /// limits (e.g. `maxMessageLengthBytes`) are enforced out of the box; pass
  /// an explicit policy to tune them. Set to `null` only to disable all limits
  /// (not recommended — this allows unbounded request bodies).
  ///
  /// [bodyReadTimeout] bounds how long the server waits for a full request
  /// body. When set, slow request bodies are rejected with `408` instead of
  /// being buffered indefinitely (slowloris mitigation). It also rejects a
  /// client that sends `Expect: 100-continue`, because dart:io never answers
  /// that header and the client's own fallback wait (curl: 1s) runs inside
  /// this budget — measured, 500ms + the header gives a 408 where the same
  /// request without it succeeds in 0.02s. See
  /// [RpcHttpResponderTransport.bodyReadTimeout] for the numbers and the
  /// options.
  RpcHttpServer({
    required String host,
    required int port,
    required void Function(RpcResponderEndpoint) onEndpointCreated,
    RpcHttpCorsPolicy? corsPolicy,
    RpcSecurityPolicy? securityPolicy = const RpcSecurityPolicy(),
    Duration? bodyReadTimeout,
    LogScope? logger,
    LogController? logController,
  }) : _host = host,
       _port = port,
       _corsPolicy = corsPolicy,
       _securityPolicy = securityPolicy,
       _bodyReadTimeout = bodyReadTimeout,
       _onEndpointCreated = onEndpointCreated,
       _logController = logController,
       _logger = logger?.child('HttpServer');

  @override
  bool get isRunning => _isRunning;

  /// The port the server is actually listening on, or `null` before
  /// [afterModulesStart] has bound the port. When constructed with port `0`,
  /// this returns the OS-assigned ephemeral port after binding.
  int? get actualPort => _httpServer?.port;

  @override
  List<RpcResponderEndpoint> get endpoints =>
      _endpoint != null ? [_endpoint!] : const [];

  /// Creates the transport. Port binding is deferred to [afterModulesStart].
  ///
  /// Calling this twice is a no-op, as it is on both sibling servers
  /// ([RpcHttp2Server] and `RpcWebSocketServer` each open with
  /// `if (_isRunning) return;`). Without the guard the second call overwrote
  /// [_transport], and the first one — already handed to an endpoint if phase
  /// two had run — became unreachable to [stop].
  ///
  /// The guard is on [_transport], not on [isRunning]: [isRunning] only goes
  /// true at the END of [afterModulesStart], so between the two phases it
  /// reports false while a transport very much exists.
  @override
  Future<void> start() async {
    if (_transport != null) {
      _logger?.warning('start() called again; the server is already set up');
      return;
    }
    _transport = RpcHttpResponderTransport(
      corsPolicy: _corsPolicy,
      securityPolicy: _securityPolicy,
      bodyReadTimeout: _bodyReadTimeout,
      logger: _logger,
    );
    _logger?.debug(
      'Transport created — port binding deferred to afterModulesStart',
    );
  }

  /// Call this inside [RpcApp.server]'s `afterModulesStart` callback.
  ///
  /// Creates the [RpcResponderEndpoint], calls [onEndpointCreated] so the
  /// framework registers interceptors and contracts (DI is ready at this
  /// point), then binds the shelf server on [host]:[port].
  ///
  /// [preamble] is an optional shelf [Handler] mounted in front of the RPC
  /// handler via [Cascade]. Use it for webhook endpoints or other HTTP
  /// concerns that must be handled before RPC routing.
  Future<void> afterModulesStart({Handler? preamble}) async {
    // Same reasoning as the guard in start(), with a much sharper consequence:
    // a second call re-bound a second port and overwrote _httpServer, so the
    // FIRST listener stayed open with nothing holding it. Measured, both ports
    // probed with a real HTTP request after stop():
    //
    //   first  bind : 58355 -> HTTP 200  (before stop)
    //   after stop(): 58355 -> HTTP 503, still listening, forever
    //                 58357 -> no answer (correctly closed)
    //   contracts disposed: [1]  -- endpoint #0 was never released
    //
    // A dead server squatting on a port and answering 503 to everything is
    // worse than a closed one: a supervisor that rebinds cannot, and a health
    // check that only looks for a live socket says the port is fine.
    if (_httpServer != null) {
      _logger?.warning(
        'afterModulesStart() called again; already listening on '
        'http://$_host:${_httpServer!.port}',
      );
      return;
    }

    final transport = _transport!;
    final endpoint = RpcResponderEndpoint(
      transport: transport,
      logger: _logController,
    );
    _endpoint = endpoint;
    _onEndpointCreated(endpoint);

    // Start the endpoint here, as both sibling servers do
    // (RpcHttp2Server._handleConnection and RpcWebSocketServer
    // ._handleConnection each call endpoint.start() right after their own
    // onEndpointCreated). This one did not, so an application written by
    // analogy registered its contracts and got a server that accepted
    // connections and answered nothing at all:
    //
    //   app calls endpoint.start()        : echo-ok
    //   app does NOT call endpoint.start(): HUNG, the server answered nothing
    //
    // A silent hang, with no error on either side, for a callback the other
    // two servers do not require.
    //
    // Safe when the application starts it too: startResponderListening()
    // guards on `_respIsListening` precisely because the http2 server and the
    // shipped examples both do this.
    endpoint.start();

    final Handler handler;
    if (preamble != null) {
      handler = Cascade().add(preamble).add(transport.handler).handler;
    } else {
      handler = transport.handler;
    }

    try {
      _httpServer = await shelf_io.serve(handler, _host, _port);
    } catch (_) {
      // The bind is the one fallible step here, and it fails for the most
      // ordinary reason there is: the port is taken. The endpoint above has
      // already been created, handed to onEndpointCreated (so it holds the
      // application's contracts) and started. Release it, because until this
      // catch existed nothing could -- stop() gave up on `!_isRunning`, and
      // _isRunning is set on the line after the bind. Measured, counting
      // contract dispose() calls after a failed bind followed by stop():
      //
      //   disposed = []      endpoints = 1
      //
      // i.e. the app's contracts kept everything they held for the life of the
      // process, and server.endpoints still handed out the dead endpoint.
      _endpoint = null;
      try {
        await endpoint.close();
      } catch (e) {
        _logger?.warning('Error closing endpoint after a failed bind: $e');
      }
      // Put the server back exactly where start() left it, so the ordinary
      // response to "address in use" -- wait and call afterModulesStart()
      // again -- still works. RpcEndpointBase.close() closes the transport it
      // was handed, so without this rebuild the retry bound successfully and
      // then answered 503 to every request:
      //
      //   retry bound      : ok on 59296
      //   call after retry : RpcStatusException(14): HTTP 503 from /Svc/echo
      //
      // which trades a leak for silent unavailability -- a worse bug than the
      // one being fixed.
      _transport = RpcHttpResponderTransport(
        corsPolicy: _corsPolicy,
        securityPolicy: _securityPolicy,
        bodyReadTimeout: _bodyReadTimeout,
        logger: _logger,
      );
      rethrow;
    }
    _isRunning = true;
    _logger?.info('Listening on http://$_host:${_httpServer!.port}');
  }

  /// Releases everything this server owns, whichever phase it reached.
  ///
  /// Deliberately NOT guarded on [isRunning]. That flag means "phase two
  /// finished", and it is set on the last line of [afterModulesStart] -- so
  /// guarding on it made stop() a no-op for every state in which setup was
  /// abandoned partway, which is exactly when cleanup matters. Each field is
  /// taken and cleared before it is closed, so this stays idempotent and so a
  /// later [start] begins from a clean slate.
  @override
  Future<void> stop() async {
    _isRunning = false;

    final httpServer = _httpServer;
    final endpoint = _endpoint;
    final transport = _transport;
    _httpServer = null;
    _endpoint = null;
    _transport = null;

    // Listener first: no new request can arrive while the endpoint is closing.
    try {
      await httpServer?.close(force: true);
    } catch (e) {
      _logger?.warning('Error closing the HTTP server: $e');
    }
    try {
      await endpoint?.close();
    } catch (e) {
      _logger?.warning('Error closing endpoint: $e');
    }
    // Closing the endpoint closes the transport it was given; this covers the
    // case where start() ran and afterModulesStart() never did, so there is a
    // transport but no endpoint to carry it.
    try {
      await transport?.close();
    } catch (e) {
      _logger?.warning('Error closing transport: $e');
    }
    _logger?.debug('Stopped');
  }
}
