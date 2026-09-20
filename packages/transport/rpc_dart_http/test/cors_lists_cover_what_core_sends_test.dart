// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// The CORS header lists were a hand-copy of "what core sends", and the copy had
// fallen behind the original in both directions.
//
// ALLOW: `caller_pipeline.dart` puts `x-route-service` on every call and every
// ping, and `x-request-id` on every call, while the required allow-list held
// only grpc-timeout, grpc-encoding and grpc-accept-encoding. A cross-origin
// browser therefore sent a header the preflight did not name. `content-type`
// was in the operator-facing DEFAULT rather than the required list, so an
// operator who passed their own `allowedHeaders` silently dropped
// `application/grpc` -- which is not CORS-safelisted -- and broke every call.
//
// EXPOSE: `RpcMetadata.forTrailer` writes `grpc-status-details-bin` whenever a
// status carries details, and the expose-list did not name it, so the details
// were unreadable from a browser. That is the same field B-64 drops on five of
// seven trailer paths -- two independent routes to the same loss.
//
// Neither shows up server-side: the server answers correctly and the browser
// discards the response.

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_http/rpc_dart_http.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

const _origin = 'https://app.example';

/// The header names in a preflight's `Access-Control-Allow-Headers`.
Set<String> _allowed(RpcHttpCorsPolicy policy) =>
    _listed(policy, 'access-control-allow-headers');

/// The header names in a preflight's `Access-Control-Expose-Headers`.
Set<String> _exposed(RpcHttpCorsPolicy policy) =>
    _listed(policy, 'access-control-expose-headers');

Set<String> _listed(RpcHttpCorsPolicy policy, String header) {
  final response = policy.handlePreflight(
    Request(
      'OPTIONS',
      Uri.parse('http://127.0.0.1/Svc/Echo'),
      headers: const {'origin': _origin},
    ),
  );
  return (response.headers[header] ?? '')
      .split(',')
      .map((part) => part.trim().toLowerCase())
      .where((part) => part.isNotEmpty)
      .toSet();
}

void main() {
  final policy = RpcHttpCorsPolicy(allowedOrigins: const [_origin]);

  group('the allow-list names every header core puts on a request', () {
    // CONTROL: the three that were already there. If these regress the list is
    // broken outright rather than merely incomplete.
    test('CONTROL: the gRPC negotiation headers are allowed', () {
      expect(
        _allowed(policy),
        containsAll(<String>[
          RpcHeaders.grpcTimeout,
          RpcHeaders.grpcEncoding,
          RpcHeaders.grpcAcceptEncoding,
        ]),
      );
    });

    test('x-route-service is allowed', () {
      expect(
        _allowed(policy),
        contains(RpcHeaders.xRouteService),
        reason:
            'caller_pipeline sends it on every call and every ping, so a '
            'preflight that omits it refuses traffic this library generates',
      );
    });

    test('x-request-id and x-trace-id survive an operator override', () {
      // Against the DEFAULT policy this passes either way — both headers are in
      // the default `allowedHeaders`, which is not what the fix changed. The
      // claim is that they are REQUIRED, so an operator who replaces that list
      // cannot drop them.
      final custom = RpcHttpCorsPolicy(
        allowedOrigins: const [_origin],
        allowedHeaders: const ['authorization'],
      );
      expect(
        _allowed(custom),
        containsAll(<String>[RpcHeaders.xRequestId, RpcHeaders.xTraceId]),
      );
    });

    test('content-type is allowed even when the operator overrides the list', () {
      // The bug this guards: content-type lived in the DEFAULT `allowedHeaders`,
      // which an operator replaces wholesale. application/grpc is not
      // CORS-safelisted, so losing it fails every cross-origin call.
      final custom = RpcHttpCorsPolicy(
        allowedOrigins: const [_origin],
        allowedHeaders: const ['authorization'],
      );
      expect(_allowed(custom), contains(RpcHeaders.contentType));
      expect(
        _allowed(custom),
        contains('authorization'),
        reason: 'the operator list must still be additive',
      );
    });
  });

  group('the expose-list names every header core writes on a response', () {
    test('CONTROL: status, message and the encodings are exposed', () {
      expect(
        _exposed(policy),
        containsAll(<String>[
          RpcHeaders.grpcStatus,
          RpcHeaders.grpcMessage,
          RpcHeaders.grpcEncoding,
          RpcHeaders.grpcAcceptEncoding,
        ]),
      );
    });

    test('grpc-status-details-bin is exposed', () {
      expect(
        _exposed(policy),
        contains(RpcHeaders.grpcStatusDetails),
        reason:
            'forTrailer writes it whenever a status carries details, and it is '
            'the only place those details exist on the wire',
      );
    });

    test('extraExposedHeaders is additive, not a replacement', () {
      final custom = RpcHttpCorsPolicy(
        allowedOrigins: const [_origin],
        extraExposedHeaders: const ['x-server-build'],
      );
      expect(_exposed(custom), contains('x-server-build'));
      expect(_exposed(custom), contains(RpcHeaders.grpcStatusDetails));
    });
  });

  // GUARD: the lists are reached through a preflight, and a denied origin must
  // not get one at all. Widening what is listed must not widen who is answered.
  test('a denied origin is still refused outright', () {
    final response = policy.handlePreflight(
      Request(
        'OPTIONS',
        Uri.parse('http://127.0.0.1/Svc/Echo'),
        headers: const {'origin': 'https://evil.example'},
      ),
    );
    expect(response.statusCode, 403);
    expect(response.headers['access-control-allow-headers'], isNull);
  });
}
