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
  final void Function(RpcResponderEndpoint) _onEndpointCreated;
  final LogScope? _logger;

  RpcHttpResponderTransport? _transport;
  RpcResponderEndpoint? _endpoint;
  HttpServer? _httpServer;
  bool _isRunning = false;

  RpcHttpServer({
    required String host,
    required int port,
    required void Function(RpcResponderEndpoint) onEndpointCreated,
    RpcHttpCorsPolicy? corsPolicy,
    LogScope? logger,
  })  : _host = host,
        _port = port,
        _corsPolicy = corsPolicy,
        _onEndpointCreated = onEndpointCreated,
        _logger = logger?.child('HttpServer');

  @override
  bool get isRunning => _isRunning;

  @override
  List<RpcResponderEndpoint> get endpoints =>
      _endpoint != null ? [_endpoint!] : const [];

  /// Creates the transport. Port binding is deferred to [afterModulesStart].
  @override
  Future<void> start() async {
    _transport = RpcHttpResponderTransport(
      corsPolicy: _corsPolicy,
      logger: _logger,
    );
    _logger?.debug('Transport created — port binding deferred to afterModulesStart');
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
    final transport = _transport!;
    _endpoint = RpcResponderEndpoint(transport: transport);
    _onEndpointCreated(_endpoint!);

    final Handler handler;
    if (preamble != null) {
      handler = Cascade().add(preamble).add(transport.handler).handler;
    } else {
      handler = transport.handler;
    }

    _httpServer = await shelf_io.serve(handler, _host, _port);
    _isRunning = true;
    _logger?.info('Listening on http://$_host:$_port');
  }

  @override
  Future<void> stop() async {
    if (!_isRunning) return;
    _isRunning = false;
    await _httpServer?.close(force: true);
    await _endpoint?.close();
    _logger?.debug('Stopped');
  }
}