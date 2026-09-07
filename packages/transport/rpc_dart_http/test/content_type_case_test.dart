// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// RFC 9110 s8.3.1 makes a media type's type and subtype CASE-INSENSITIVE, and
// this responder compared the raw header string, so a peer within spec was
// turned away:
//
//     application/grpc        -> 200
//     application/grpc+proto  -> 200
//     Application/GRPC        -> 415   <- legal, and refused
//     APPLICATION/GRPC+PROTO  -> 415   <- legal, and refused
//     text/plain              -> 415   (correct)
//
// The asymmetry is what named it: the HTTP/2 caller and the core responder
// pipeline both lowercase before the same check, and only this one did not.

@TestOn('vm')
library;

import 'dart:io';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_http/rpc_dart_http.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

final class _Svc extends RpcResponderContract {
  _Svc() : super('Svc');

  @override
  void setup() {
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'ping',
      handler: (r, {RpcContext? context}) async => 'pong'.rpc,
      requestCodec: _codec,
      responseCodec: _codec,
    );
  }
}

late HttpServer _server;

Future<int> _statusFor(String contentType) async {
  final client = HttpClient();
  try {
    final request = await client.postUrl(
      Uri.parse('http://127.0.0.1:${_server.port}/Svc/ping'),
    );
    request.headers.set('content-type', contentType);
    request.headers.set('te', 'trailers');
    request.add(RpcMessageFrame.encode(_codec.serialize('x'.rpc)));
    final response = await request.close();
    await response.drain<void>();
    return response.statusCode;
  } finally {
    client.close(force: true);
  }
}

void main() {
  setUp(() async {
    final transport = RpcHttpResponderTransport(
      securityPolicy: const RpcSecurityPolicy(),
    );
    final responder = RpcResponderEndpoint(transport: transport);
    responder.registerServiceContract(_Svc());
    responder.start();
    _server = await shelf_io.serve(transport.handler, '127.0.0.1', 0);
    addTearDown(() async {
      await responder.close();
      await _server.close(force: true);
    });
  });

  test('an uppercase gRPC content type is accepted', () async {
    expect(await _statusFor('Application/GRPC'), 200);
  });

  test('an uppercase subtype is accepted too', () async {
    expect(await _statusFor('APPLICATION/GRPC+PROTO'), 200);
  });

  test('GUARD: the lowercase forms still work', () async {
    expect(await _statusFor('application/grpc'), 200);
    expect(await _statusFor('application/grpc+proto'), 200);
  });

  test('GUARD: a genuinely wrong content type is still refused', () async {
    // Load-bearing: lowercasing must widen the check to CASE only, not to
    // anything that happens to contain the word.
    expect(await _statusFor('text/plain'), 415);
    expect(await _statusFor('application/json'), 415);
    expect(await _statusFor('x-application/grpc'), 415);
  });
}
