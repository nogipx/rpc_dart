// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// connect() returns once the TCP socket is open. A peer that accepts and never
// speaks h2 would otherwise read as a live connection for good, with every
// call on it waiting forever. connectTimeout also bounds the wait for the
// peer's first SETTINGS.

@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_http2/rpc_dart_http2.dart';
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

final class _Echo extends RpcResponderContract {
  _Echo() : super('Echo');

  @override
  void setup() {
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'u',
      handler: (r, {RpcContext? context}) async => r,
      requestCodec: _codec,
      responseCodec: _codec,
    );
  }
}

Future<RpcString> _call(RpcCallerEndpoint caller) =>
    caller.unaryRequest<RpcString, RpcString>(
      serviceName: 'Echo',
      methodName: 'u',
      request: 'x'.rpc,
      requestCodec: _codec,
      responseCodec: _codec,
    );

void main() {
  test('WITNESS a call to a peer that never sends SETTINGS ends', () async {
    final held = <Socket>[];
    final silent = await ServerSocket.bind('127.0.0.1', 0);
    silent.listen((s) {
      held.add(s);
      s.listen((_) {}, onError: (_) {});
    });
    addTearDown(() async {
      for (final s in held) {
        s.destroy();
      }
      await silent.close();
    });

    final transport = await RpcHttp2CallerTransport.connect(
      host: '127.0.0.1',
      port: silent.port,
      connectTimeout: const Duration(milliseconds: 300),
    );
    final caller = RpcCallerEndpoint(transport: transport);
    addTearDown(caller.close);

    final outcome = await _call(caller)
        .then<Object>((r) => r, onError: (Object e) => e)
        .timeout(
          const Duration(seconds: 5),
          onTimeout: () => 'still waiting after 5 s',
        );
    expect(
      outcome,
      isA<RpcStatusException>().having(
        (e) => e.statusCode,
        'statusCode',
        RpcStatus.unavailable,
      ),
    );
  });

  test('GUARD a live connection outlasts the SETTINGS bound', () async {
    final server = RpcHttp2Server(
      host: '127.0.0.1',
      port: 0,
      onEndpointCreated: (e) => e.registerServiceContract(_Echo()),
    );
    await server.start();
    addTearDown(server.stop);

    final transport = await RpcHttp2CallerTransport.connect(
      host: '127.0.0.1',
      port: server.port,
      connectTimeout: const Duration(milliseconds: 200),
    );
    final caller = RpcCallerEndpoint(transport: transport);
    addTearDown(caller.close);

    expect((await _call(caller)).value, 'x');
    await Future<void>.delayed(const Duration(milliseconds: 600));
    expect((await _call(caller)).value, 'x');
    expect((await transport.health()).level, RpcHealthLevel.healthy);
  });
}
