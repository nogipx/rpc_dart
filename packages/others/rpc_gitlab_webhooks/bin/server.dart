/// GitLab Webhook Bridge Server
///
/// Receives HTTP webhooks from GitLab and exposes them as RPC streams
/// over WebSocket for downstream clients.
///
/// Configuration (CLI args or env vars):
///
///   --host           WEBHOOK_HOST      Bind address            (default: 0.0.0.0)
///   --port           WEBHOOK_PORT      HTTP/WS port            (default: 8080)
///   --webhook-path   WEBHOOK_PATH      GitLab webhook path     (default: /webhook)
///   --secret         WEBHOOK_SECRET    X-Gitlab-Token value    (default: none)
///   --verbose        WEBHOOK_VERBOSE   Enable verbose logging  (default: false)
///
/// Usage:
///   dart run bin/server.dart --port 8080 --secret my-secret
///   dart compile exe bin/server.dart -o gitlab-webhook-server
///   ./gitlab-webhook-server --port 8080 --secret my-secret
library;

import 'dart:async';
import 'dart:io';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_websocket/rpc_dart_websocket.dart';
import 'package:rpc_gitlab_webhooks/rpc_gitlab_webhooks.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

void main(List<String> args) async {
  final config = _ServerConfig.fromArgs(args);

  if (config.showHelp) {
    _printHelp();
    exit(0);
  }

  final handler = GitlabWebhookHandler(
    secretToken: config.secret,
  );

  final wsConnections = StreamController<WebSocketChannel>.broadcast();

  final rpcServer = RpcWebSocketServer.createWithContracts(
    connections: wsConnections.stream,
    contracts: [GitlabWebhookResponder(handler: handler)],
    logger: config.verbose ? RpcLogger('rpc-server') : null,
  );
  await rpcServer.start();

  final httpServer = await HttpServer.bind(config.host, config.port);

  _log('GitLab Webhook Bridge started');
  _log('  Bind address : ${config.host}:${config.port}');
  _log('  Webhook path : ${config.webhookPath}');
  _log('  Secret token : ${config.secret != null ? '***' : 'none (open)'}');
  _log('  RPC clients  : connect via ws://${config.host}:${config.port}/');

  // Handle OS signals for graceful shutdown
  _setupShutdown(() async {
    _log('\nShutting down...');
    await rpcServer.stop();
    await wsConnections.close();
    await httpServer.close(force: false);
    handler.dispose();
    _log('Stopped.');
  });

  await for (final req in httpServer) {
    _handleRequest(
      req,
      config: config,
      handler: handler,
      wsConnections: wsConnections,
      verbose: config.verbose,
    );
  }
}

Future<void> _handleRequest(
  HttpRequest req, {
  required _ServerConfig config,
  required GitlabWebhookHandler handler,
  required StreamController<WebSocketChannel> wsConnections,
  required bool verbose,
}) async {
  if (WebSocketTransformer.isUpgradeRequest(req)) {
    // WebSocket client connecting for RPC
    try {
      final ws = await WebSocketTransformer.upgrade(req);
      final channel = IOWebSocketChannel(ws);
      wsConnections.add(channel);
      if (verbose) {
        _log('[ws] client connected from ${req.connectionInfo?.remoteAddress.address}');
      }
    } catch (e) {
      _log('[error] WebSocket upgrade failed: $e');
      req.response.statusCode = HttpStatus.internalServerError;
      await req.response.close();
    }
    return;
  }

  if (req.method == 'POST' && req.uri.path == config.webhookPath) {
    // GitLab webhook payload
    final eventType = req.headers.value('x-gitlab-event') ?? 'unknown';
    final status = await handler.handleHttpRequest(req);
    req.response.statusCode = status;
    await req.response.close();

    if (verbose) {
      final symbol = status == HttpStatus.ok ? '✓' : '✗';
      _log('[$symbol] webhook: $eventType → HTTP $status');
    }
    return;
  }

  if (req.method == 'GET' && req.uri.path == '/healthz') {
    req.response
      ..statusCode = HttpStatus.ok
      ..headers.contentType = ContentType.text
      ..write('ok');
    await req.response.close();
    return;
  }

  req.response.statusCode = HttpStatus.notFound;
  await req.response.close();
}

void _setupShutdown(Future<void> Function() onShutdown) {
  var shutdownInProgress = false;

  void shutdown([_]) async {
    if (shutdownInProgress) return;
    shutdownInProgress = true;
    await onShutdown();
    exit(0);
  }

  ProcessSignal.sigint.watch().listen(shutdown);
  // SIGTERM is not available on Windows
  if (!Platform.isWindows) {
    ProcessSignal.sigterm.watch().listen(shutdown);
  }
}

void _log(String message) {
  final time = DateTime.now().toIso8601String().substring(11, 23);
  stdout.writeln('[$time] $message');
}

void _printHelp() {
  stdout.write('''
gitlab-webhook-server — GitLab Webhook → RPC Bridge

USAGE:
  gitlab-webhook-server [options]

OPTIONS:
  --host <addr>          Bind address (default: 0.0.0.0)
                         Env: WEBHOOK_HOST
  --port <num>           HTTP/WebSocket port (default: 8080)
                         Env: WEBHOOK_PORT
  --webhook-path <path>  Path for GitLab webhook POST (default: /webhook)
                         Env: WEBHOOK_PATH
  --secret <token>       X-Gitlab-Token secret (default: none)
                         Env: WEBHOOK_SECRET
  --verbose              Enable verbose request logging
                         Env: WEBHOOK_VERBOSE=true
  --help                 Show this help

ENDPOINTS:
  POST <webhook-path>    GitLab sends webhooks here
  GET  /                 WebSocket upgrade — RPC clients connect here
  GET  /healthz          Health check (returns "ok")

COMPILE:
  dart compile exe bin/server.dart -o gitlab-webhook-server
''');
}

// ── Config ────────────────────────────────────────────────────────────────────

class _ServerConfig {
  final String host;
  final int port;
  final String webhookPath;
  final String? secret;
  final bool verbose;
  final bool showHelp;

  const _ServerConfig({
    required this.host,
    required this.port,
    required this.webhookPath,
    required this.secret,
    required this.verbose,
    required this.showHelp,
  });

  factory _ServerConfig.fromArgs(List<String> args) {
    final env = Platform.environment;

    String? getArg(String name) {
      final idx = args.indexOf('--$name');
      if (idx != -1 && idx + 1 < args.length) return args[idx + 1];
      return null;
    }

    bool hasFlag(String name) => args.contains('--$name');

    return _ServerConfig(
      host: getArg('host') ?? env['WEBHOOK_HOST'] ?? '0.0.0.0',
      port: int.tryParse(getArg('port') ?? env['WEBHOOK_PORT'] ?? '') ?? 8080,
      webhookPath: getArg('webhook-path') ?? env['WEBHOOK_PATH'] ?? '/webhook',
      secret: getArg('secret') ?? env['WEBHOOK_SECRET'],
      verbose: hasFlag('verbose') || env['WEBHOOK_VERBOSE'] == 'true',
      showHelp: hasFlag('help') || hasFlag('h'),
    );
  }
}
