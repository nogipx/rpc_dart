// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// Web-safe smoke test for the HTTP/1.1 CALLER transport.
//
// RpcHttpCallerTransport imports only dart:async + package:http + rpc_dart --
// no dart:io -- so it compiles to dart2js and runs in the browser. Mobile and
// Flutter-Web apps embed exactly this client. This file proves a unary call
// round-trips through the transport on JS without any real server: an injected
// package:http MockClient plays the server, decoding the gRPC-framed request
// body and returning a canned gRPC-framed response with trailer headers.
//
// The server transport (rpc_http_server.dart) uses dart:io/shelf and is
// intentionally NOT exercised here -- it is VM-only and out of web scope.
@TestOn('vm || node || browser')
library;

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_http/rpc_dart_http.dart';
import 'package:test/test.dart';

/// Builds a fake [http.Client] that behaves like an rpc_dart HTTP responder:
/// it decodes the gRPC-framed [RpcString] request body, applies [transform]
/// to its value, and returns a 200 response whose body is the gRPC-framed
/// echo plus a `grpc-status: 0` trailer header.
http.Client _echoClient(String Function(String request) transform) {
  return MockClient((request) async {
    // The request body is one gRPC-framed message: 5-byte prefix + payload.
    final framed = request.bodyBytes;
    final payload = framed.sublist(RpcConstants.messagePrefixSize);
    final decoded = RpcString.codec.deserialize(Uint8List.fromList(payload));

    final replyBytes = RpcString.codec.serialize(RpcString(transform(decoded.value)));
    final responseBody = RpcMessageFrame.encode(replyBytes);

    return http.Response.bytes(
      responseBody,
      200,
      headers: {
        RpcHeaders.contentType: 'application/grpc+proto',
        RpcHeaders.grpcStatus: '${RpcStatus.ok}',
      },
      request: request,
    );
  });
}

void main() {
  test('unary call round-trips through the caller transport on JS', () async {
    final transport = RpcHttpCallerTransport(
      baseUrl: 'http://web-smoke.invalid',
      httpClient: _echoClient((req) => 'Echo: $req'),
    );
    final client = RpcCallerEndpoint(
      transport: transport,
      debugLabel: 'WebSmokeClient',
    );
    addTearDown(client.close);

    final response = await client.unaryRequest<RpcString, RpcString>(
      serviceName: 'Echo',
      methodName: 'Echo',
      requestCodec: RpcString.codec,
      responseCodec: RpcString.codec,
      request: RpcString('hello from JS'),
    );

    expect(response.value, 'Echo: hello from JS');
  });

  test('custom request headers reach the injected client on JS', () async {
    String? seenTenant;

    final transport = RpcHttpCallerTransport(
      baseUrl: 'http://web-smoke.invalid',
      httpClient: MockClient((request) async {
        seenTenant = request.headers['x-tenant-id'];
        final payload =
            request.bodyBytes.sublist(RpcConstants.messagePrefixSize);
        final decoded = RpcString.codec.deserialize(Uint8List.fromList(payload));
        final replyBytes =
            RpcString.codec.serialize(RpcString('seen ${decoded.value}'));
        return http.Response.bytes(
          RpcMessageFrame.encode(replyBytes),
          200,
          headers: {
            RpcHeaders.contentType: 'application/grpc+proto',
            RpcHeaders.grpcStatus: '${RpcStatus.ok}',
          },
          request: request,
        );
      }),
    );
    final client = RpcCallerEndpoint(transport: transport);
    addTearDown(client.close);

    final response = await client.unaryRequest<RpcString, RpcString>(
      serviceName: 'Echo',
      methodName: 'Echo',
      requestCodec: RpcString.codec,
      responseCodec: RpcString.codec,
      request: RpcString('ping'),
      context: RpcContextUtils.withBearerToken('test-token')
          .withAdditionalHeaders({'x-tenant-id': 'tenant-42'}),
    );

    expect(response.value, 'seen ping');
    expect(seenTenant, 'tenant-42');
  });

  test('non-200 HTTP status surfaces as a gRPC error on JS', () async {
    final transport = RpcHttpCallerTransport(
      baseUrl: 'http://web-smoke.invalid',
      httpClient: MockClient((request) async {
        return http.Response('boom', 503, request: request);
      }),
    );
    final client = RpcCallerEndpoint(transport: transport);
    addTearDown(client.close);

    await expectLater(
      client.unaryRequest<RpcString, RpcString>(
        serviceName: 'Echo',
        methodName: 'Fail',
        requestCodec: RpcString.codec,
        responseCodec: RpcString.codec,
        request: RpcString('x'),
      ),
      throwsA(anything),
    );
  });
}
