// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// rpc_dart's own caller refuses an unsupported grpc-encoding LOCALLY, before
// anything reaches the wire. That is why the server's side of the same
// negotiation went unnoticed: no rpc_dart client can reach it, only a foreign
// peer can (see rpc_dart_http2/test/unsupported_encoding_reply_test.dart, which
// speaks raw package:http2 to assert the server now answers UNIMPLEMENTED with
// `grpc-accept-encoding`).
//
// This file pins the caller half: the local refusal must NAME the alternatives
// too, for the same reason the wire one must -- a refusal that does not say
// what would work leaves the caller guessing.

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

final class _Contract extends RpcResponderContract {
  _Contract() : super('Svc');

  @override
  void setup() {
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'Echo',
      handler: (request, {RpcContext? context}) async => 'ok'.rpc,
      requestCodec: _codec,
      responseCodec: _codec,
    );
  }
}

Future<Object?> _callWith(String? encoding) async {
  final (client, server) = RpcChannelTransport.pair();
  final responder = RpcResponderEndpoint(transport: server);
  responder.registerServiceContract(_Contract());
  responder.start();
  final caller = RpcCallerEndpoint(transport: client);

  Object? error;
  try {
    await caller
        .unaryRequest<RpcString, RpcString>(
          serviceName: 'Svc',
          methodName: 'Echo',
          request: 'x'.rpc,
          requestCodec: _codec,
          responseCodec: _codec,
          context: encoding == null
              ? null
              : (RpcContextBuilder()
                      ..withHeaders({RpcHeaders.grpcEncoding: encoding}))
                    .build(),
        )
        .timeout(const Duration(seconds: 5));
  } catch (e) {
    error = e;
  }

  await caller.close();
  await responder.close();
  await client.close();
  await server.close();
  return error;
}

void main() {
  test('the caller refuses an unsupported encoding, naming what works', () async {
    final error = await _callWith('br');

    expect(error, isNotNull);
    expect(
      error.toString(),
      contains('identity'),
      reason:
          'the refusal must list the algorithms that would have worked, or the '
          'caller has nothing to act on',
    );
    expect(error.toString(), contains('br'));
  });

  test('GUARD: no encoding at all still succeeds', () async {
    expect(await _callWith(null), isNull);
  });

  test('GUARD: identity still succeeds', () async {
    expect(await _callWith('identity'), isNull);
  });
}
