// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// `/a.b/c` and `/a/b.c` once resolved to one method. A service name may carry a
// dot and a method name may not, so only the first form reaches `a.b`/`c`; this
// drives the second over HTTP/1.1, with and without a policy on the transport.

@TestOn('vm')
library;

import 'dart:io';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_http/rpc_dart_http.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

var _handlerRuns = 0;

final class _Contract extends RpcResponderContract {
  _Contract() : super('a.b');

  @override
  void setup() {
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'c',
      handler: (request, {RpcContext? context}) async {
        _handlerRuns++;
        return 'ok'.rpc;
      },
      requestCodec: _codec,
      responseCodec: _codec,
    );
  }
}

/// Posts one call to [path]; returns the HTTP status and grpc-status.
Future<String> _call(int port, String path) async {
  final client = HttpClient();
  try {
    final body = RpcMessageFrame.encode(
      _codec.serialize('x'.rpc),
      compressed: false,
    );
    final request = await client.postUrl(
      Uri.parse('http://127.0.0.1:$port$path'),
    );
    request.headers.set('content-type', 'application/grpc');
    request.contentLength = body.length;
    request.add(body);
    final response = await request.close().timeout(const Duration(seconds: 5));
    await response.drain<void>();
    return '${response.statusCode} '
        '${response.headers.value('grpc-status') ?? '-'}';
  } finally {
    client.close(force: true);
  }
}

void main() {
  for (final withPolicy in [true, false]) {
    group(withPolicy ? 'with a policy' : 'without a policy', () {
      late RpcHttpResponderTransport transport;
      late RpcResponderEndpoint responder;
      late HttpServer server;

      setUp(() async {
        _handlerRuns = 0;
        transport = RpcHttpResponderTransport(
          securityPolicy: withPolicy ? const RpcSecurityPolicy() : null,
        );
        responder = RpcResponderEndpoint(transport: transport)
          ..registerServiceContract(_Contract())
          ..start();
        server = await shelf_io.serve(transport.handler, '127.0.0.1', 0);
      });

      tearDown(() async {
        await responder.close();
        await transport.close();
        await server.close(force: true);
      });

      test('/a/b.c does not reach a.b/c', () async {
        final answer = await _call(server.port, '/a/b.c');
        // The transport refuses it when it holds a policy; without one the
        // responder pipeline does, as INVALID_ARGUMENT.
        expect(answer, withPolicy ? '400 -' : '200 3');
        expect(_handlerRuns, 0, reason: answer);
      });

      test('CONTROL: /a.b/c is served', () async {
        expect(await _call(server.port, '/a.b/c'), '200 0');
        expect(_handlerRuns, 1);
      });
    });
  }
}
