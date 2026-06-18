// Audit finding 5: MCP server malformed JSON body -> unhandled exception/500
// instead of a JSON-RPC -32700 parse error.
//
// log_mcp.dart:131-135 reads the POST body and calls _processJsonRpc, which at
// line 161-162 does `jsonDecode(body) as Map<String, dynamic>`. Malformed JSON
// throws FormatException; a JSON array body throws a cast error. Neither is
// caught, so shelf returns a 500 with no JSON-RPC envelope.
//
// CORRECT behavior (JSON-RPC 2.0 spec): a parse error must return HTTP 200 with
// an error object whose code is -32700. We assert that. If we get a 500 (or a
// non -32700 response) -> CONFIRMED.

import 'dart:convert';
import 'dart:io';

import 'package:rpc_dart_log/rpc_dart_log_server.dart';
import 'package:test/test.dart';

Future<int> _freePort() async {
  final s = await HttpServer.bind('127.0.0.1', 0);
  final p = s.port;
  await s.close();
  return p;
}

void main() {
  group('finding 5: MCP malformed JSON -> JSON-RPC -32700', () {
    late LogCollectorMcpServer mcp;
    late int port;

    setUp(() async {
      port = await _freePort();
      mcp = await LogCollectorMcpServer.run(
        host: '127.0.0.1',
        collectorPort: 0,
        mcpPort: port,
        colored: false,
      );
    });

    tearDown(() async {
      await mcp.stop();
    });

    Future<HttpClientResponse> _post(String body) async {
      final client = HttpClient();
      final req = await client.postUrl(Uri.parse('http://127.0.0.1:$port/'));
      req.headers.contentType = ContentType.json;
      req.write(body);
      final resp = await req.close();
      return resp;
    }

    test('malformed JSON body returns JSON-RPC parse error (-32700)', () async {
      final resp = await _post('{ this is not valid json ');
      final body = await resp.transform(utf8.decoder).join();

      expect(
        resp.statusCode,
        200,
        reason:
            'parse error must be a JSON-RPC envelope, not a 500. '
            'Got ${resp.statusCode}: $body',
      );

      final json = jsonDecode(body) as Map<String, dynamic>;
      expect(
        json['error']?['code'],
        -32700,
        reason: 'expected JSON-RPC parse error -32700, got: $body',
      );
    });

    test('JSON array body (valid JSON, wrong shape) returns -32700', () async {
      // Valid JSON but not a Map -> the `as Map<String, dynamic>` cast throws.
      final resp = await _post('[1,2,3]');
      final body = await resp.transform(utf8.decoder).join();

      expect(
        resp.statusCode,
        200,
        reason:
            'wrong-shape body must be a JSON-RPC envelope, not a 500. '
            'Got ${resp.statusCode}: $body',
      );

      final json = jsonDecode(body) as Map<String, dynamic>;
      expect(
        json['error']?['code'],
        -32700,
        reason: 'expected JSON-RPC parse error -32700, got: $body',
      );
    });
  });
}
