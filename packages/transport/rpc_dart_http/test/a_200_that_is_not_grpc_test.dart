// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// The HTTP/2 caller has refused a 200 whose content-type is not gRPC since it
// met a proxy's HTML error page. Its HTTP/1.1 sibling had no such check, so the
// page's bytes went to the parser:
//
//   HTTP/1.1 caller   status=13 "Invalid compression flag in gRPC message: 60"
//   HTTP/2 caller     status=13 "Invalid content-type for gRPC: \"text/html\""
//
// 60 is '<'. Same status, and a diagnostic that names a framing detail instead
// of the problem -- nothing in it says a proxy answered, so the next step is to
// go looking at the codec.

@TestOn('vm')
library;

import 'dart:io';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_http/rpc_dart_http.dart';
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

const _htmlBody = '<html><body>502 from a proxy</body></html>';

/// Answers every request with a 200 whose `content-type` is [contentType]
/// (null = none) and [body] as the payload.
Future<HttpServer> _serverAnswering({
  required String? contentType,
  required List<int> body,
  Map<String, String> extraHeaders = const {},
}) async {
  final server = await HttpServer.bind('127.0.0.1', 0);
  server.forEach((request) async {
    await request.drain<void>();
    request.response.statusCode = 200;
    // dart:io sets one of its own otherwise, so an "absent" arm needs this.
    request.response.headers.removeAll('content-type');
    if (contentType != null) {
      request.response.headers.set('content-type', contentType);
    }
    extraHeaders.forEach(request.response.headers.set);
    request.response.add(body);
    await request.response.close();
  }).ignore();
  addTearDown(() => server.close(force: true));
  return server;
}

/// One unary call against [server], as `'ok'` or `'status=N message'`.
Future<String> _call(HttpServer server) async {
  final transport = RpcHttpCallerTransport(
    baseUrl: 'http://127.0.0.1:${server.port}',
  );
  final caller = RpcCallerEndpoint(transport: transport);
  addTearDown(() async {
    await caller.close();
    await transport.close();
  });

  try {
    final response = await caller.unaryRequest<RpcString, RpcString>(
      serviceName: 'Svc',
      methodName: 'echo',
      request: 'x'.rpc,
      requestCodec: _codec,
      responseCodec: _codec,
      transferMode: RpcDataTransferMode.codec,
    );
    return 'ok ${response.value}';
  } on RpcStatusException catch (e) {
    return 'status=${e.statusCode} ${e.message}';
  }
}

void main() {
  // WITNESS. Without the check this reads
  // `Invalid compression flag in gRPC message: 60`.
  test(
    'a 200 answering HTML names the content-type, not a framing byte',
    () async {
      final server = await _serverAnswering(
        contentType: 'text/html',
        body: _htmlBody.codeUnits,
      );

      expect(
        await _call(server),
        'status=${RpcStatus.internal} '
        'Invalid content-type for gRPC: "text/html"',
        reason:
            'the sibling HTTP/2 caller names it; this one described the first '
            'byte of an HTML page as a compression flag',
      );
    },
  );

  // GUARD. Lenient, like the HTTP/2 caller: a Trailers-Only answer carries no
  // content-type at all, so refusing absent here would refuse every one of them.
  test('GUARD: a response with no content-type is still accepted', () async {
    final server = await _serverAnswering(
      contentType: null,
      body: RpcMessageFrame.encode(_codec.serialize('pong'.rpc)),
      extraHeaders: const {'grpc-status': '0'},
    );

    expect(await _call(server), 'ok pong');
  });

  // GUARD. The check must not turn away a real gRPC answer -- including the
  // `+proto` subtype this transport's own caller sends.
  test('GUARD: a real gRPC answer still arrives', () async {
    for (final contentType in const [
      'application/grpc',
      'application/grpc+proto',
      'Application/GRPC',
    ]) {
      final server = await _serverAnswering(
        contentType: contentType,
        body: RpcMessageFrame.encode(_codec.serialize('pong'.rpc)),
        extraHeaders: const {'grpc-status': '0'},
      );
      expect(await _call(server), 'ok pong', reason: contentType);
    }
  });
}
