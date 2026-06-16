// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;

import 'log_console.dart';
import 'log_server.dart';
import 'mcp_buffer.dart';

/// MCP server that exposes log collector data to AI assistants via HTTP.
///
/// Tools:
/// - `rpc_log_sources` -- overview: devices, scope stats, recent errors, cursor
/// - `rpc_log_get_logs` -- query with filters (device, level, scope, message, traceId, collapse)
class LogCollectorMcpServer {
  final LogCollectorServer _server;
  final LogCollectorConsole _console;
  final LogCollectorMcpBuffer _buffer;
  HttpServer? _httpServer;

  LogCollectorMcpServer._({
    required LogCollectorServer server,
    required LogCollectorConsole console,
    required LogCollectorMcpBuffer buffer,
  })  : _server = server,
        _console = console,
        _buffer = buffer {
    _server.onConnection.listen(_console.printConnection);
    _server.onRecord.listen((tagged) {
      _console.printRecord(tagged);
      _buffer.addRecord(tagged);
    });
  }

  /// Start the log collector (WebSocket) and MCP (HTTP) servers.
  static Future<LogCollectorMcpServer> run({
    String host = '127.0.0.1',
    int collectorPort = 9500,
    int mcpPort = 9501,
    int bufferSize = 5000,
    bool colored = true,
  }) async {
    final server = await _buildCollectorServer(host, collectorPort);
    final console = LogCollectorConsole(colored: colored);
    final buffer = LogCollectorMcpBuffer(maxRecords: bufferSize);

    final mcp = LogCollectorMcpServer._(
      server: server,
      console: console,
      buffer: buffer,
    );

    mcp._httpServer = await shelf_io.serve(mcp._handleRequest, host, mcpPort);
    return mcp;
  }

  static Future<LogCollectorServer> _buildCollectorServer(
      String host, int port) async {
    final server = LogCollectorServer(host: host, port: port);
    await server.start();
    return server;
  }

  /// Stop both servers.
  Future<void> stop() async {
    await _httpServer?.close(force: true);
    await _server.stop();
  }

  // ---------------------------------------------------------------------------
  // HTTP handler
  // ---------------------------------------------------------------------------

  Future<Response> _handleRequest(Request request) async {
    final path = request.url.path;
    final base =
        'http://${request.requestedUri.host}:${request.requestedUri.port}';

    if (request.method == 'GET' &&
        path == '.well-known/oauth-authorization-server') {
      return _json({
        'issuer': base,
        'authorization_endpoint': '$base/authorize',
        'token_endpoint': '$base/token',
        'registration_endpoint': '$base/register',
        'response_types_supported': ['code'],
        'grant_types_supported': ['authorization_code'],
        'code_challenge_methods_supported': ['S256'],
        'token_endpoint_auth_methods_supported': ['none'],
      });
    }

    if (request.method == 'POST' && path == 'register') {
      Map<String, dynamic> body;
      try {
        final decoded = jsonDecode(await request.readAsString());
        body = decoded is Map<String, dynamic> ? decoded : <String, dynamic>{};
      } on FormatException {
        body = <String, dynamic>{};
      }
      return _json({
        'client_id': 'rpc-dart-log-local',
        'client_name': body['client_name'] ?? 'claude',
        'redirect_uris': body['redirect_uris'] ?? [],
        'grant_types': ['authorization_code'],
        'response_types': ['code'],
        'token_endpoint_auth_method': 'none',
      });
    }

    if (request.method == 'GET' && path == 'authorize') {
      // DEV-ONLY, UNAUTHENTICATED flow. To avoid an open redirect we only
      // honour loopback redirect targets; anything else is rejected.
      final redirectUri = request.url.queryParameters['redirect_uri'];
      final state = request.url.queryParameters['state'];
      if (redirectUri != null) {
        if (!_isLoopbackRedirect(redirectUri)) {
          return Response(400, body: 'redirect_uri must target loopback');
        }
        final sep = redirectUri.contains('?') ? '&' : '?';
        final location =
            '$redirectUri${sep}code=local-dev-code${state != null ? '&state=$state' : ''}';
        return Response.found(location);
      }
      return Response.ok('authorized');
    }

    if (request.method == 'POST' && path == 'token') {
      // DEV-ONLY, UNAUTHENTICATED flow. Issue a fresh random token per call
      // instead of a static, predictable one.
      return _json({
        'access_token': _randomToken(),
        'token_type': 'Bearer',
        'expires_in': 999999,
      });
    }

    if (request.method == 'POST') {
      final body = await request.readAsString();
      final result = _processJsonRpc(body);
      return Response.ok(result, headers: {'content-type': 'application/json'});
    }

    if (request.method == 'GET') {
      return _json({'name': 'rpc_dart_log', 'version': '0.1.0'});
    }

    return Response(405);
  }

  static final _tokenRandom = Random.secure();

  /// A fresh, unpredictable opaque token for the dev-only OAuth flow.
  static String _randomToken() {
    final bytes = List<int>.generate(24, (_) => _tokenRandom.nextInt(256));
    return base64Url.encode(bytes);
  }

  /// True only if [redirectUri] is a syntactically valid URI whose host is a
  /// loopback address (localhost / 127.0.0.0/8 / ::1). Used to block the OAuth
  /// open-redirect in this dev-only flow.
  static bool _isLoopbackRedirect(String redirectUri) {
    final uri = Uri.tryParse(redirectUri);
    if (uri == null) return false;
    final host = uri.host.toLowerCase();
    if (host == 'localhost') return true;
    if (host == '::1') return true;
    final addr = InternetAddress.tryParse(host);
    if (addr != null && addr.isLoopback) return true;
    return false;
  }

  Response _json(Map<String, dynamic> body) =>
      Response.ok(jsonEncode(body), headers: {'content-type': 'application/json'});

  // ---------------------------------------------------------------------------
  // MCP JSON-RPC
  // ---------------------------------------------------------------------------

  static const _mcpInstructions = '''
Real-time log collector for rpc_dart applications.

Investigation strategy:
1. Call rpc_log_sources FIRST -- devices, scope stats, recent errors, cursor.
2. If errors visible, use rpc_log_get_logs with level=error or traceId prefix filter.
3. Use "cursor" param to get only new logs since last query (incremental tail).
4. Use "collapse:true" when dealing with high-volume repetitive logs (retries, polling).
5. TraceIds in sources are shown as 8-char prefixes -- pass prefix to traceId filter.''';

  String _processJsonRpc(String body) {
    final Object? decoded;
    try {
      decoded = jsonDecode(body);
    } on FormatException {
      // Malformed JSON -> JSON-RPC parse error.
      return _rpcError(null, -32700, 'Parse error');
    }
    if (decoded is! Map<String, dynamic>) {
      // Well-formed JSON but not a JSON-RPC object (e.g. an array). The body
      // cannot be interpreted as a request, so we report a parse error.
      return _rpcError(null, -32700, 'Parse error');
    }
    final json = decoded;
    final id = json['id'];
    final method = json['method'] as String?;

    return switch (method) {
      'initialize' => _rpcResult(id, {
          'protocolVersion': '2024-11-05',
          'capabilities': {'tools': {}},
          'serverInfo': {'name': 'rpc_dart_log', 'version': '0.1.0'},
          'instructions': _mcpInstructions,
        }),
      'notifications/initialized' => _rpcResult(id, {}),
      'tools/list' => _rpcResult(id, {
          'tools': [_sourcesTool, _getLogsTool],
        }),
      'tools/call' =>
        _handleToolCall(id, json['params'] as Map<String, dynamic>?),
      _ => _rpcError(id, -32601, 'Method not found: $method'),
    };
  }

  String _rpcResult(Object? id, Map<String, dynamic> result) =>
      jsonEncode({'jsonrpc': '2.0', 'id': id, 'result': result});

  String _rpcError(Object? id, int code, String message) => jsonEncode({
        'jsonrpc': '2.0',
        'id': id,
        'error': {'code': code, 'message': message},
      });

  String _rpcToolResult(Object? id, String text) => _rpcResult(id, {
        'content': [
          {'type': 'text', 'text': text}
        ],
      });

  // ---------------------------------------------------------------------------
  // Tool dispatch
  // ---------------------------------------------------------------------------

  String _handleToolCall(Object? id, Map<String, dynamic>? params) {
    final toolName = params?['name'] as String?;
    final args = params?['arguments'] as Map<String, dynamic>? ?? {};

    final content = switch (toolName) {
      'rpc_log_sources' => _buffer.sources(_server.sessions),
      'rpc_log_get_logs' => _buffer.getLogs(args),
      _ => 'Unknown tool: $toolName',
    };

    return _rpcToolResult(id, content);
  }

  // ---------------------------------------------------------------------------
  // Tool definitions
  // ---------------------------------------------------------------------------

  static final _sourcesTool = {
    'name': 'rpc_log_sources',
    'description':
        'Overview of all log sources: connected devices, scope stats (total/errors/warnings/spans), '
        'recent errors (last 5 inline), active traceIds as 8-char prefixes with error counts, '
        'and current cursor. ALWAYS call this first before querying logs.',
    'inputSchema': {'type': 'object', 'properties': {}},
    'annotations': {'readOnlyHint': true},
  };

  static final _getLogsTool = {
    'name': 'rpc_log_get_logs',
    'description':
        'Query log records with precise filters. Returns records with device labels, timestamps, '
        'levels, scopes, messages, errors, traceIds, and data fields. '
        'Use collapse:true for high-volume repetitive logs (retries, polling).',
    'inputSchema': {
      'type': 'object',
      'properties': {
        'count': {
          'type': 'integer',
          'description': 'Max records to return (default: 50, max: 500). Returns chronological.',
        },
        'level': {
          'type': 'string',
          'description': 'Minimum log level filter',
          'enum': ['internal', 'trace', 'debug', 'info', 'warning', 'error', 'fatal'],
        },
        'scope': {
          'type': 'string',
          'description': 'Scope prefix filter (e.g. "engine" matches "engine.connection")',
        },
        'device': {
          'type': 'string',
          'description': 'Device label filter (substring, case-insensitive)',
        },
        'traceId': {
          'type': 'string',
          'description':
              'Filter by traceId prefix (8+ chars from rpc_log_sources, or full ID). '
              'Matches any traceId starting with this value.',
        },
        'message': {
          'type': 'string',
          'description':
              'Regex pattern matched against log messages (case-insensitive). '
              'Use | for OR: "timeout|refused", anchors: "^conn", wildcards: "auth.*fail". '
              'Plain strings work as substring search.',
        },
        'since': {
          'type': 'string',
          'description':
              'Show only records after this point. '
              'Relative: "30s", "2m", "1h". Absolute (today): "14:55", "14:55:30". '
              'Ignored when cursor is also set (cursor takes priority).',
        },
        'cursor': {
          'type': 'integer',
          'description':
              'Return only records after this cursor value. Use for incremental tail.',
        },
        'type': {
          'type': 'string',
          'description': 'Filter by record type: "event" or "span". Omit for both.',
          'enum': ['event', 'span'],
        },
        'collapse': {
          'type': 'boolean',
          'description':
              'Collapse repeating sequences of 1-3 lines into [xN] / [xN cycles] form '
              '(default: false). Use when logs have retries, polling loops, or repeated patterns.',
        },
        'no_data': {
          'type': 'boolean',
          'description':
              'Omit structured data fields from output (default: false). '
              'Use when data payloads are large and not relevant to the investigation.',
        },
        'context': {
          'type': 'integer',
          'description':
              'Show N lines before and after each matching record (default: 0, max: 20). '
              'Match lines are prefixed with ">", context lines with spaces. '
              'Non-contiguous windows are separated by "---". '
              'Useful to understand what led up to an error. Disables collapse.',
        },
      },
    },
    'annotations': {'readOnlyHint': true},
  };
}
