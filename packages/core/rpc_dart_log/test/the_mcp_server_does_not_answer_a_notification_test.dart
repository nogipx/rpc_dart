// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:rpc_dart_log/rpc_dart_log_server.dart';
import 'package:test/test.dart';

// JSON-RPC 2.0 forbids answering a notification (a message without an id),
// and MCP over HTTP accepts one with 202 and no body.

Future<int> _freePort() async {
  final s = await HttpServer.bind('127.0.0.1', 0);
  final p = s.port;
  await s.close();
  return p;
}

void main() {
  test('a notification is accepted with 202 and no body', () async {
    final port = await _freePort();
    final mcp = await LogCollectorMcpServer.run(
      host: '127.0.0.1',
      collectorPort: 0,
      mcpPort: port,
      colored: false,
    );
    addTearDown(mcp.stop);

    final client = HttpClient();
    addTearDown(client.close);
    final post = await client.postUrl(Uri.parse('http://127.0.0.1:$port/'));
    post.headers.contentType = ContentType.json;
    post.write(
      jsonEncode({'jsonrpc': '2.0', 'method': 'notifications/initialized'}),
    );
    final response = await post.close();
    final body = await response.transform(utf8.decoder).join();

    expect(response.statusCode, 202);
    expect(body, isEmpty);
  });
}
