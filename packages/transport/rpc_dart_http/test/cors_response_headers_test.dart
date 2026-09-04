// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// Two holes in how the CORS policy reached the wire.
//
// 1. Only _flushResponse applied it -- the SUCCESS path. Every rejection went
//    out bare: 415 for a non-gRPC content-type, 400 for a bad method path or a
//    metadata violation, 503 at the concurrency ceiling or after close(), 408
//    on a body-read timeout. A browser cannot read a cross-origin response
//    without Access-Control-Allow-Origin, so a web client saw an opaque CORS
//    failure instead of the status the server chose -- the difference between
//    "your content-type is wrong" and no diagnosis at all.
//
// 2. No `Vary: Origin`, anywhere. The policy REFLECTS the request origin when
//    it is on the allowlist, so the response is not the same for every caller,
//    and a shared cache may hand one origin's response to another.
//
// Measured against a policy allowing exactly one origin:
//
//                                  before                    after
//   CONTROL successful call        ACAO set,   Vary ABSENT   ACAO set, Vary Origin
//   preflight OPTIONS              ACAO set,   Vary ABSENT   ACAO set, Vary Origin
//   415 non-gRPC content-type      ACAO ABSENT, Vary ABSENT  ACAO set, Vary Origin
//   400 method path too long       ACAO ABSENT, Vary ABSENT  ACAO set, Vary Origin

import 'dart:async';
import 'dart:io';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_http/rpc_dart_http.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:test/test.dart';

const _allowed = 'https://app.example';
const _denied = 'https://evil.example';
final _codec = RpcCodec(RpcString.fromJson);

final class _Contract extends RpcResponderContract {
  _Contract() : super('Svc');

  @override
  void setup() {
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'Echo',
      handler: (request, {RpcContext? context}) async => 'pong'.rpc,
      requestCodec: _codec,
      responseCodec: _codec,
    );
  }
}

typedef Probe =
    Future<({int status, String? acao, String? vary})> Function(
      String method,
      String path, {
      String? origin,
      Map<String, String> headers,
      List<int>? body,
    });

/// Serves a transport built with [corsPolicy] and returns a request helper.
Future<Probe> _serve(RpcHttpCorsPolicy corsPolicy) async {
  final transport = RpcHttpResponderTransport(
    corsPolicy: corsPolicy,
    securityPolicy: const RpcSecurityPolicy(),
  );
  final responder = RpcResponderEndpoint(transport: transport);
  responder.registerServiceContract(_Contract());
  responder.start();

  final server = await shelf_io.serve(transport.handler, '127.0.0.1', 0);
  final base = Uri.parse('http://127.0.0.1:${server.port}');
  final client = HttpClient();

  addTearDown(() async {
    client.close(force: true);
    await responder.close();
    await transport.close();
    await server.close(force: true);
  });

  return (
    String method,
    String path, {
    String? origin,
    Map<String, String> headers = const {},
    List<int>? body,
  }) async {
    final req = await client.openUrl(method, base.replace(path: path));
    if (origin != null) req.headers.set('origin', origin);
    headers.forEach(req.headers.set);
    if (body == null) {
      req.contentLength = 0;
    } else {
      req.contentLength = body.length;
      req.add(body);
    }
    final res = await req.close().timeout(const Duration(seconds: 10));
    await res.drain<void>();
    return (
      status: res.statusCode,
      acao: res.headers.value('access-control-allow-origin'),
      vary: res.headers.value('vary'),
    );
  };
}

List<int> get _grpcBody =>
    RpcMessageFrame.encode(_codec.serialize('x'.rpc), compressed: false);

void main() {
  group('an allowlisted origin', () {
    late Probe probe;

    setUp(() async {
      probe = await _serve(RpcHttpCorsPolicy(allowedOrigins: const [_allowed]));
    });

    test('CONTROL: a successful call carries the policy', () async {
      final res = await probe(
        'POST',
        '/Svc/Echo',
        origin: _allowed,
        headers: const {'content-type': 'application/grpc'},
        body: _grpcBody,
      );
      expect(res.status, 200);
      expect(res.acao, _allowed);
      expect(res.vary, contains('Origin'));
    });

    test('a 415 rejection carries the policy', () async {
      final res = await probe(
        'POST',
        '/Svc/Echo',
        origin: _allowed,
        headers: const {'content-type': 'text/plain'},
      );
      expect(res.status, 415);
      expect(
        res.acao,
        _allowed,
        reason:
            'a browser cannot read a cross-origin response without ACAO, so '
            'the 415 was invisible to the page that caused it',
      );
      expect(res.vary, contains('Origin'));
    });

    test('a 400 rejection carries the policy', () async {
      final res = await probe(
        'POST',
        '/${'a' * 5000}',
        origin: _allowed,
        headers: const {'content-type': 'application/grpc'},
      );
      expect(res.status, 400);
      expect(res.acao, _allowed);
      expect(res.vary, contains('Origin'));
    });

    test('a preflight carries Vary alongside the reflected origin', () async {
      final res = await probe('OPTIONS', '/Svc/Echo', origin: _allowed);
      expect(res.status, 204);
      expect(res.acao, _allowed);
      expect(res.vary, contains('Origin'));
    });
  });

  group('an origin that is not allowlisted', () {
    late Probe probe;

    setUp(() async {
      probe = await _serve(RpcHttpCorsPolicy(allowedOrigins: const [_allowed]));
    });

    // GUARD: attaching the policy to rejections must not attach it to origins
    // the policy denies. Getting this wrong turns every error path into an open
    // CORS endpoint.
    test('gets no ACAO on a rejection, but is still Vary-marked', () async {
      final res = await probe(
        'POST',
        '/Svc/Echo',
        origin: _denied,
        headers: const {'content-type': 'text/plain'},
      );
      expect(res.status, 415);
      expect(res.acao, isNull);
      expect(
        res.vary,
        contains('Origin'),
        reason:
            'the ACAO-less response is itself origin-dependent -- an allowed '
            'origin would have got one -- so a cache must not reuse it',
      );
    });

    test('gets no ACAO on a successful call', () async {
      final res = await probe(
        'POST',
        '/Svc/Echo',
        origin: _denied,
        headers: const {'content-type': 'application/grpc'},
        body: _grpcBody,
      );
      expect(res.status, 200);
      expect(res.acao, isNull);
    });

    test('is refused at preflight', () async {
      final res = await probe('OPTIONS', '/Svc/Echo', origin: _denied);
      expect(res.status, 403);
      expect(res.acao, isNull);
      expect(res.vary, contains('Origin'));
    });
  });

  group('a wildcard policy', () {
    late Probe probe;

    setUp(() async {
      probe = await _serve(RpcHttpCorsPolicy(allowedOrigins: const ['*']));
    });

    // GUARD: with '*' every caller gets the same constant header, so the
    // response does NOT vary by origin and saying it does only fragments
    // caches.
    test('answers every origin with * and no Vary', () async {
      final res = await probe(
        'POST',
        '/Svc/Echo',
        origin: _denied,
        headers: const {'content-type': 'text/plain'},
      );
      expect(res.status, 415);
      expect(res.acao, '*');
      expect(res.vary, isNull);
    });
  });

  test('the closed default adds no headers at all', () async {
    // GUARD: with an empty allowlist nobody ever gets an ACAO, so the response
    // is origin-INDEPENDENT and must not claim to vary -- Vary there would only
    // fragment caches for a server that serves every origin identically.
    final probe = await _serve(RpcHttpCorsPolicy());
    final res = await probe(
      'POST',
      '/Svc/Echo',
      origin: _denied,
      headers: const {'content-type': 'text/plain'},
    );
    expect(res.status, 415);
    expect(res.acao, isNull);
    expect(res.vary, isNull);
  });

  test('a request with no Origin header is unaffected', () async {
    // GUARD: same-origin traffic sends no Origin and must not acquire an ACAO.
    final probe = await _serve(
      RpcHttpCorsPolicy(allowedOrigins: const [_allowed]),
    );
    final res = await probe(
      'POST',
      '/Svc/Echo',
      headers: const {'content-type': 'application/grpc'},
      body: _grpcBody,
    );
    expect(res.status, 200);
    expect(res.acao, isNull);
  });
}
