// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

@TestOn('vm')
library;

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
  test('the MCP server reports the version in the pubspec', () async {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    final version = RegExp(
      r'^version:\s*(\S+)',
      multiLine: true,
    ).firstMatch(pubspec)!.group(1);

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
    final uri = Uri.parse('http://127.0.0.1:$port/');

    final post = await client.postUrl(uri);
    post.headers.contentType = ContentType.json;
    post.write(jsonEncode({'jsonrpc': '2.0', 'id': 1, 'method': 'initialize'}));
    final initialize =
        jsonDecode(await (await post.close()).transform(utf8.decoder).join())
            as Map<String, dynamic>;
    expect(initialize['result']['serverInfo']['version'], version);

    final get = await (await client.getUrl(uri)).close();
    final info =
        jsonDecode(await get.transform(utf8.decoder).join())
            as Map<String, dynamic>;
    expect(info['version'], version);
  });
}
