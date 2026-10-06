// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// RpcHttpCorsPolicy validates its inputs once, in the constructor, so it must
// keep what it validated: a caller's list mutated afterwards must not reach the
// wire. Origins match case-insensitively, headers go out once each, and a
// preflight is cacheable by default.

import 'package:rpc_dart_http/rpc_dart_http.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

Map<String, String> _apply(RpcHttpCorsPolicy p, String? origin) {
  final headers = <String, String>{};
  p.applyTo(headers, origin);
  return headers;
}

Response _preflight(RpcHttpCorsPolicy p, String origin) => p.handlePreflight(
  Request('OPTIONS', Uri.parse('http://x/Svc/M'), headers: {'origin': origin}),
);

void main() {
  test('a list mutated after construction does not reach the wire', () {
    final origins = ['https://a.example'];
    final policy = RpcHttpCorsPolicy(
      allowedOrigins: origins,
      allowCredentials: true,
    );
    origins.add('*');

    final headers = _apply(policy, 'https://evil.example');
    expect(headers['access-control-allow-origin'], isNull);
    expect(headers['access-control-allow-credentials'], isNull);
  });

  test('a configured origin matches whatever case it was written in', () {
    final policy = RpcHttpCorsPolicy(
      allowedOrigins: ['https://App.Example.com'],
    );
    expect(
      _apply(policy, 'https://app.example.com')['access-control-allow-origin'],
      'https://app.example.com',
    );
  });

  test('each allowed header is listed once', () {
    final policy = RpcHttpCorsPolicy(
      allowedOrigins: ['https://a.example'],
      allowedHeaders: ['content-type', 'Authorization', 'x-custom'],
    );
    final listed = _preflight(
      policy,
      'https://a.example',
    ).headers['access-control-allow-headers']!.split(', ');
    expect(listed.toSet(), hasLength(listed.length));
    expect(listed, containsAll(['authorization', 'x-custom']));
  });

  test('a preflight is cacheable by default', () {
    final policy = RpcHttpCorsPolicy(allowedOrigins: ['https://a.example']);
    expect(
      _preflight(policy, 'https://a.example').headers['access-control-max-age'],
      '600',
    );
  });
}
