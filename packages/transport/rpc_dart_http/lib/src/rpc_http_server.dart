// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';
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
  final Duration? _bodyIdleTimeout;
  final void Function(RpcResponderEndpoint) _onEndpointCreated;
  final LogScope? _logger;
  final LogController? _logController;

  RpcHttpResponderTransport? _transport;
  RpcResponderEndpoint? _endpoint;
  HttpServer? _httpServer;
  bool _isRunning = false;

  /// Claimed by [afterModulesStart] before its first await, so a concurrent
  /// second call cannot get past the guard while the bind is in flight.
  bool _binding = false;

  /// Creates an HTTP/1.1 RPC server.
  ///
  /// [securityPolicy] bounds request body size, header sizes, and concurrent
  /// requests. It defaults to a non-null [RpcSecurityPolicy] so the built-in
  /// limits (e.g. `maxMessageLengthBytes`) are enforced out of the box; pass
  /// an explicit policy to tune them. Set to `null` only to disable all limits
  /// (not recommended — this allows unbounded request bodies).
  ///
  /// [bodyIdleTimeout] refuses with `408` a request body that stops arriving
  /// for that long (slowloris mitigation), 30 seconds by default; a body that
  /// keeps arriving is never refused by it. [bodyReadTimeout] is an optional
  /// ceiling on the whole body read. It also rejects a client sending
  /// `Expect: 100-continue`, whose fallback wait runs inside this budget — see
  /// [RpcHttpResponderTransport.bodyReadTimeout] for that trade-off.
  RpcHttpServer({
    required String host,
    required int port,
    required void Function(RpcResponderEndpoint) onEndpointCreated,
    RpcHttpCorsPolicy? corsPolicy,
    RpcSecurityPolicy? securityPolicy = const RpcSecurityPolicy(),
    Duration? bodyReadTimeout,
    Duration? bodyIdleTimeout = const Duration(seconds: 30),
    LogScope? logger,
    LogController? logController,
  }) : _host = host,
       _port = port,
       _corsPolicy = corsPolicy,
       _securityPolicy = securityPolicy,
       _bodyReadTimeout = bodyReadTimeout,
       _bodyIdleTimeout = bodyIdleTimeout,
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
  /// Calling this twice is a no-op, as on both sibling servers. Without the
  /// guard the second call overwrites [_transport], and the first — already
  /// handed to an endpoint if phase two has run — becomes unreachable to [stop].
  ///
  /// The guard is on [_transport], NOT on [isRunning]: [isRunning] only goes
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
      bodyIdleTimeout: _bodyIdleTimeout,
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
    // a second call binds a second port and overwrites _httpServer, so the
    // FIRST listener stays open with nothing holding it -- and stop() cannot
    // reach it. A dead server squatting on a port and answering 503 to
    // everything is worse than a closed one: a supervisor that rebinds cannot,
    // and a health check looking only for a live socket says the port is fine.
    // `_httpServer` alone cannot hold this: it is assigned AFTER the bind's
    // await, so two concurrent callers both passed the guard, both built an
    // endpoint over the SAME transport, and the one that lost the bind ran the
    // catch below — closing the shared transport under the winner and nulling
    // `_endpoint`. Measured: the socket stays bound, `isRunning` reports true,
    // `endpoints` is empty and every call is answered UNAVAILABLE.
    //
    // So the slot is claimed SYNCHRONOUSLY, before anything can suspend. The
    // claim is released in the bind's catch, because the documented response to
    // "address in use" is to call this again.
    if (_httpServer != null || _binding) {
      _logger?.warning(
        'afterModulesStart() called again; already '
        '${_httpServer != null ? 'listening on http://$_host:${_httpServer!.port}' : 'binding'}',
      );
      return;
    }
    // Named, not dereferenced. `_transport!` crashed with `Null check operator
    // used on a null value` — a message that says nothing about the mistake,
    // which is calling phase two without phase one, or after a stop(). The two
    // phases are an ordering contract and a violation of it should read like one.
    final transport = _transport;
    if (transport == null) {
      _binding = false;
      throw StateError(
        'afterModulesStart() needs start() first: there is no transport to '
        'serve on. A stop() also clears it, so a restart calls both again.',
      );
    }
    _binding = true;
    final bound = Completer<void>();
    _bind = bound.future;
    try {
      await _bindAndServe(transport, preamble);
    } finally {
      bound.complete();
    }
  }

  /// The bind of an [afterModulesStart] in progress. [stop] waits it out:
  /// before the bind lands there is nothing to close, and the listener that
  /// lands after it was reachable by nothing.
  Future<void>? _bind;

  Future<void> _bindAndServe(
    RpcHttpResponderTransport transport,
    Handler? preamble,
  ) async {
    final endpoint = RpcResponderEndpoint(
      transport: transport,
      logger: _logController,
    );
    _endpoint = endpoint;
    _onEndpointCreated(endpoint);

    // Started HERE, as both sibling servers do right after their own
    // onEndpointCreated. Leave it to the application and one written by analogy
    // with those two registers its contracts and gets a server that accepts
    // connections and answers nothing at all -- a silent hang, no error on
    // either side.
    //
    // Safe when the application starts it too: startResponderListening() guards
    // on `_respIsListening` precisely because the http2 server and the shipped
    // examples both do this.
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
      // ordinary reason there is: the port is taken. By now the endpoint has
      // been created, handed to onEndpointCreated (so it holds the
      // application's contracts) and started -- and nothing else can release
      // it, because stop() gives up on `!_isRunning` and _isRunning is set on
      // the line after the bind. Without this the contracts keep everything
      // they hold for the life of the process.
      _endpoint = null;
      try {
        await endpoint.close();
      } catch (e) {
        _logger?.warning('Error closing endpoint after a failed bind: $e');
      }
      // Put the server back exactly where start() left it, so the ordinary
      // response to "address in use" -- wait, call afterModulesStart() again --
      // still works. RpcEndpointBase.close() closes the transport it was
      // handed, so without this rebuild the retry binds successfully and then
      // answers 503 to every request: a leak traded for silent unavailability,
      // which is worse.
      _transport = RpcHttpResponderTransport(
        corsPolicy: _corsPolicy,
        securityPolicy: _securityPolicy,
        bodyReadTimeout: _bodyReadTimeout,
        bodyIdleTimeout: _bodyIdleTimeout,
        logger: _logger,
      );
      // Released with the rest: the documented recovery is to call this again.
      _binding = false;
      rethrow;
    }
    _isRunning = true;
    _logger?.info('Listening on http://$_host:${_httpServer!.port}');
  }

  /// Waits, up to [budget], for the transport to finish its pending requests.
  ///
  /// `pendingRequests` is the responder transport's own count of shelf requests
  /// it has accepted and not yet answered, reported through [health]. A request
  /// whose handler outlives its response is not counted -- the same caveat the
  /// sibling servers' drains carry.
  Future<void> _drainRequests(
    RpcHttpResponderTransport? transport,
    Duration budget,
  ) async {
    if (transport == null) return;

    return drainUntilIdle(
      pending: () => transport.pendingRequests,
      budget: budget,
      logger: _logger,
      unit: 'request',
    );
  }

  /// Completes every still-pending response BEFORE the sockets carrying them go.
  ///
  /// The transport's `close()` answers each one with a 503, and those 503s travel
  /// over exactly the connections `close(force: true)` destroys -- so in the other
  /// order the server promised an answer and delivered a reset. Measured with a
  /// 200 ms drain budget against a handler taking 30 s:
  /// `ClientException: Connection closed before full header was received`, where it
  /// now reads `HTTP 503`.
  ///
  /// The yield is what gets it onto the wire: completing the future only hands the
  /// response to shelf, which still has to WRITE it, and there is nothing to await
  /// for that -- `HttpServer.close()` completes on port release, not on response
  /// flush. One turn is enough for a 503, which is small by construction; a large
  /// body could still be cut.
  ///
  /// Idempotent, so `endpoint.close()` closing the same transport afterwards is a
  /// no-op.
  Future<void> _answerStragglers(RpcHttpResponderTransport? transport) async {
    if (transport == null) return;
    await transport.close();
    await Future<void>.delayed(Duration.zero);
  }

  /// Releases everything this server owns, whichever phase it reached.
  ///
  /// Deliberately NOT guarded on [isRunning]. That flag means "phase two
  /// finished" and is set on the last line of [afterModulesStart], so guarding
  /// on it makes stop() a no-op for every state in which setup was abandoned
  /// partway — exactly when cleanup matters. Each field is taken and cleared
  /// before it is closed, so this stays idempotent and a later [start] begins
  /// from a clean slate.
  ///
  /// [drainTimeout], when given, lets in-flight requests finish first. Without
  /// it every request running at that moment dies — correctly, with a prompt
  /// `UNAVAILABLE`, but a rolling deploy drops them.
  ///
  /// `HttpServer.close(force: false)` is NOT a drain, which is worth stating
  /// because it reads like one: it stops the server listening and completes as
  /// soon as the port is released, merely declining to kill active connections.
  /// Closing the endpoint straight afterwards kills the handler anyway, and the
  /// caller then HANGS — the connection stays open with no answer ever coming.
  ///
  /// So the wait is explicit, as on the other two servers: stop accepting, poll
  /// until the transport reports no pending requests, and only then close the
  /// endpoint that has to answer them.
  @override
  Future<void> stop({Duration? drainTimeout}) async {
    final bind = _bind;
    if (_binding && _httpServer == null && bind != null) await bind;
    _isRunning = false;
    // Or a server stopped and started again is refused by its own bind claim:
    // the claim survives a successful bind, and `_httpServer` is cleared below.
    _binding = false;

    final httpServer = _httpServer;
    final endpoint = _endpoint;
    final transport = _transport;
    _httpServer = null;
    _endpoint = null;
    _transport = null;

    // Listener first: no new request can arrive while the endpoint is closing.
    //
    // `close(force: false)` only stops accepting -- it completes as soon as the
    // port is released and does NOT wait for active connections, which is why
    // the explicit `_drainRequests` below exists and must not be removed as
    // redundant. What the ordering buys is that the endpoint stays alive while
    // that drain runs, so the requests already in flight can still be answered.
    try {
      if (drainTimeout != null && httpServer != null) {
        // Stop accepting without killing what is running...
        await httpServer.close();
        // ...then actually wait for it.
        await _drainRequests(transport, drainTimeout);
        // Anything still going when the budget expires is cut here -- AFTER it has
        // been answered.
        await _answerStragglers(transport);
        await httpServer.close(force: true);
      } else {
        await _answerStragglers(transport);
        await httpServer?.close(force: true);
      }
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
