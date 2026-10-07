// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// Two request-metadata edges, the same on every transport: a value with leading
// or trailing whitespace is refused before it is sent (RFC 9113 §8.2.1 forbids
// it, and HTTP/1.1 would trim it silently), and a `grpc-` header other than the
// three the framework negotiates never reaches the handler.

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

final class _Svc extends RpcResponderContract {
  _Svc() : super('Svc');
  @override
  void setup() {
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'Get',
      handler: (r, {RpcContext? context}) async =>
          (context?.getHeader(r.value) ?? '<absent>').rpc,
      requestCodec: _codec,
      responseCodec: _codec,
    );
  }
}

Future<String> _call(Map<String, String> headers, String read) async {
  final (client, server) = RpcChannelTransport.pair();
  final responder = RpcResponderEndpoint(transport: server)
    ..registerServiceContract(_Svc())
    ..start();
  final caller = RpcCallerEndpoint(transport: client);
  addTearDown(() async {
    await caller.close();
    await responder.close();
  });
  try {
    final r = await caller.unaryRequest<RpcString, RpcString>(
      serviceName: 'Svc',
      methodName: 'Get',
      request: read.rpc,
      requestCodec: _codec,
      responseCodec: _codec,
      context: RpcContext.withHeaders(headers),
    );
    return r.value;
  } on RpcStatusException catch (e) {
    return 'status ${e.statusCode}';
  }
}

void main() {
  test('a value with edge whitespace is refused before it is sent', () async {
    expect(
      await _call({'x-pad': '  v  w  '}, 'x-pad'),
      'status ${RpcStatus.invalidArgument}',
    );
  });

  test('inner whitespace is fine', () async {
    expect(await _call({'x-pad': 'v  w'}, 'x-pad'), 'v  w');
  });

  test('a reserved grpc- header never reaches the handler', () async {
    expect(await _call({'grpc-status': '7'}, 'grpc-status'), '<absent>');
  });

  test('GUARD: a negotiated grpc- header still does', () async {
    expect(
      await _call(const {}, RpcHeaders.grpcAcceptEncoding),
      isNot('<absent>'),
    );
  });
}
