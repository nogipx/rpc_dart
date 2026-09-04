// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// gRPC is POST-only, and nothing checked. Measured with a body on every
// method, counting handler executions:
//
//   POST GET HEAD PUT DELETE PATCH  ->  6 of 6 ran, all grpc-status=0
//   after                           ->  1 of 6, only POST
//
// GET is the one that matters. A browser can be made to issue a cross-origin
// GET without a preflight, while a POST carrying `content-type:
// application/grpc` cannot leave the origin unprompted -- so accepting GET
// turned every unary method into something an attacker's page could trigger.
//
// RpcHttpCallerTransport hard-codes POST, which is why no test reached this:
// only a foreign caller picks the method. Same defect and same blind spot as
// 555d6855 on the HTTP/2 server, found by applying that round's rule to the
// sibling transport.
//
// Answered as HTTP 405 with `Allow`, not as a gRPC status: this transport
// already answers pre-dispatch rejections with real HTTP statuses (415, 400),
// whereas gRPC-over-HTTP/2 must always send 200 plus grpc-status.

import 'dart:async';
import 'dart:io';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_http/rpc_dart_http.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

var _handlerRuns = 0;

final class _Contract extends RpcResponderContract {
  _Contract() : super('Svc');

  @override
  void setup() {
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'Mutate',
      handler: (request, {RpcContext? context}) async {
        _handlerRuns++;
        return 'mutated'.rpc;
      },
      requestCodec: _codec,
      responseCodec: _codec,
    );
  }
}

void main() {
  late RpcHttpResponderTransport transport;
  late RpcResponderEndpoint responder;
  late HttpServer server;
  late HttpClient client;
  late Uri base;

  setUp(() async {
    _handlerRuns = 0;
    transport = RpcHttpResponderTransport(
      securityPolicy: const RpcSecurityPolicy(),
    );
    responder = RpcResponderEndpoint(transport: transport);
    responder.registerServiceContract(_Contract());
    responder.start();
    server = await shelf_io.serve(transport.handler, '127.0.0.1', 0);
    base = Uri.parse('http://127.0.0.1:${server.port}');
    client = HttpClient();
  });

  tearDown(() async {
    client.close(force: true);
    await responder.close();
    await transport.close();
    await server.close(force: true);
  });

  /// Sends one request with [method], always WITH a body -- the question is
  /// whether the server cares about the method, not whether a payload arrived.
  Future<HttpClientResponse> ask(String method, {String? origin}) async {
    final request = await client.openUrl(
      method,
      base.replace(path: '/Svc/Mutate'),
    );
    request.headers.set('content-type', 'application/grpc');
    if (origin != null) request.headers.set('origin', origin);
    final body = RpcMessageFrame.encode(
      _codec.serialize('x'.rpc),
      compressed: false,
    );
    request.contentLength = body.length;
    request.add(body);
    final response = await request.close().timeout(const Duration(seconds: 10));
    await response.drain<void>();
    return response;
  }

  test('a GET never reaches the handler', () async {
    final response = await ask('GET');

    expect(
      _handlerRuns,
      0,
      reason:
          'a cross-origin GET needs no preflight, so executing one turns every '
          'unary method into something an attacker page can trigger',
    );
    expect(response.statusCode, 405);
    expect(
      response.headers.value('allow'),
      contains('POST'),
      reason: 'a 405 should say what is allowed',
    );
  });

  test('no method other than POST reaches the handler', () async {
    for (final method in const ['GET', 'HEAD', 'PUT', 'DELETE', 'PATCH']) {
      final response = await ask(method);
      expect(response.statusCode, 405, reason: '$method must be refused');
    }
    expect(_handlerRuns, 0);
  });

  test('the refusal arrives as a status, not a dropped connection', () async {
    // Rejecting without draining the request body leaves unread bytes on the
    // socket and dart:io tears the connection down before the status is
    // flushed. Measured while writing this fix: PUT came back as a
    // SocketException instead of 405, while GET and DELETE happened to
    // survive. So this asserts the METHOD-with-a-body case specifically.
    final response = await ask('PUT');
    expect(response.statusCode, 405);
  });

  test('GUARD: POST still works', () async {
    final response = await ask('POST');
    expect(response.statusCode, 200);
    expect(_handlerRuns, 1);
  });

  test('GUARD: the refusal carries CORS headers', () async {
    // The rejection path gained CORS headers in d6721871; a browser must be
    // able to READ the 405 rather than see an opaque failure.
    final corsTransport = RpcHttpResponderTransport(
      corsPolicy: RpcHttpCorsPolicy(allowedOrigins: const ['https://app.test']),
      securityPolicy: const RpcSecurityPolicy(),
    );
    final corsResponder = RpcResponderEndpoint(transport: corsTransport);
    corsResponder.registerServiceContract(_Contract());
    corsResponder.start();
    final corsServer = await shelf_io.serve(
      corsTransport.handler,
      '127.0.0.1',
      0,
    );
    addTearDown(() async {
      await corsResponder.close();
      await corsTransport.close();
      await corsServer.close(force: true);
    });

    final request = await client.openUrl(
      'GET',
      Uri.parse('http://127.0.0.1:${corsServer.port}/Svc/Mutate'),
    );
    request.headers.set('content-type', 'application/grpc');
    request.headers.set('origin', 'https://app.test');
    request.contentLength = 0;
    final response = await request.close().timeout(const Duration(seconds: 10));
    await response.drain<void>();

    expect(response.statusCode, 405);
    expect(
      response.headers.value('access-control-allow-origin'),
      'https://app.test',
    );
  });

  test(
    'GUARD: an OPTIONS preflight is still handled by the CORS policy',
    () async {
      // OPTIONS is legitimate when a CORS policy is configured, so the method
      // check must sit AFTER the preflight branch.
      final corsTransport = RpcHttpResponderTransport(
        corsPolicy: RpcHttpCorsPolicy(
          allowedOrigins: const ['https://app.test'],
        ),
        securityPolicy: const RpcSecurityPolicy(),
      );
      final corsServer = await shelf_io.serve(
        corsTransport.handler,
        '127.0.0.1',
        0,
      );
      addTearDown(() async {
        await corsTransport.close();
        await corsServer.close(force: true);
      });

      final request = await client.openUrl(
        'OPTIONS',
        Uri.parse('http://127.0.0.1:${corsServer.port}/Svc/Mutate'),
      );
      request.headers.set('origin', 'https://app.test');
      request.contentLength = 0;
      final response = await request.close().timeout(
        const Duration(seconds: 10),
      );
      await response.drain<void>();

      expect(
        response.statusCode,
        204,
        reason: 'a preflight must not be answered with 405',
      );
    },
  );
}
