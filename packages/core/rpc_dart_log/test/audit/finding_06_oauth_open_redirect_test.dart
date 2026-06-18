// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// Audit finding 6: MCP "OAuth" open redirect + accepts any token.
//
// log_mcp.dart:111-129. The `authorize` handler (a GET endpoint, contrary to
// the audit note which says POST) reflects `redirect_uri` and `state` into a
// Location header with no validation. The `token` endpoint hands out a static
// `local-dev-token` to anyone.
//
// We spin the shelf handler in-process via LogCollectorMcpServer.run and hit the
// real endpoints. CORRECT behavior: an attacker-controlled redirect_uri must NOT
// be reflected unvalidated into the Location header, and the token endpoint must
// not issue a static predictable token. If they are -> CONFIRMED.

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
  group('finding 6: MCP OAuth open redirect / static token', () {
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

    test(
      'authorize must not reflect attacker redirect_uri unvalidated',
      () async {
        const attacker = 'https://evil.example.com/steal';
        final client = HttpClient();
        final req = await client.getUrl(
          Uri.parse(
            'http://127.0.0.1:$port/authorize?redirect_uri=${Uri.encodeQueryComponent(attacker)}&state=xyz',
          ),
        );
        req.followRedirects = false;
        final resp = await req.close();
        await resp.drain<void>();
        client.close();

        final location = resp.headers.value('location');

        expect(
          location == null || !location.startsWith(attacker),
          isTrue,
          reason:
              'Open redirect: authorize reflected attacker redirect_uri into '
              'Location header unvalidated. Status=${resp.statusCode} '
              'Location=$location',
        );
      },
    );

    test('token endpoint must not hand a static token to any caller', () async {
      final client = HttpClient();
      final req = await client.postUrl(
        Uri.parse('http://127.0.0.1:$port/token'),
      );
      req.headers.contentType = ContentType.json;
      req.write(jsonEncode({'grant_type': 'authorization_code', 'code': 'x'}));
      final resp = await req.close();
      final body = await resp.transform(utf8.decoder).join();
      client.close();

      final json = jsonDecode(body) as Map<String, dynamic>;

      expect(
        json['access_token'],
        isNot('local-dev-token'),
        reason:
            'token endpoint issued a static, predictable access_token to an '
            'unauthenticated caller: $body',
      );
    });
  });
}
