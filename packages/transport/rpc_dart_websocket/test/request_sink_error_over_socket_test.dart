// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// A bidi caller whose request sink ERRORS, over a real socket. The fix is in
// core, but the notice is a metadata frame this transport builds itself, so
// whether it reaches the peer over a wire is its own question.
//
// The server reports through a unary call on the SAME connection, which is the
// one observable every transport shares.
//
// Measured with the core notice ablated and restored:
//
//   erroring (ablated)   5 handlers still live      control   0
//   erroring (fixed)     0                          control   0

@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_websocket/io.dart';
import 'package:rpc_dart_websocket/rpc_dart_websocket.dart';
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

final class _Svc extends RpcResponderContract {
  _Svc() : super('Svc');

  int _live = 0;

  @override
  void setup() {
    addBidirectionalMethod<RpcString, RpcString>(
      methodName: 'echo',
      handler: (requests, {RpcContext? context}) async* {
        _live++;
        try {
          await for (final r in requests) {
            yield r;
          }
        } finally {
          _live--;
        }
      },
      requestCodec: _codec,
      responseCodec: _codec,
    );

    // How many handlers are still inside their body, asked over the wire.
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'live',
      handler: (r, {RpcContext? context}) async => '$_live'.rpc,
      requestCodec: _codec,
      responseCodec: _codec,
    );
  }
}

Stream<RpcString> _twoThenError() async* {
  yield 'a'.rpc;
  yield 'b'.rpc;
  throw StateError('producer died');
}

void main() {
  const calls = 5;

  late HttpServer http;
  late RpcWebSocketServer server;
  late RpcWebSocketCallerTransport client;
  late RpcCallerEndpoint caller;

  setUp(() async {
    http = await HttpServer.bind('127.0.0.1', 0);
    server = RpcWebSocketServer(
      connections: rpcWebSocketConnections(http),
      onEndpointCreated: (e) => e.registerServiceContract(_Svc()),
    );
    await server.start();
    client = await RpcWebSocketCallerTransport.connect(
      Uri.parse('ws://127.0.0.1:${http.port}'),
    );
    caller = RpcCallerEndpoint(transport: client);
  });

  tearDown(() async {
    await caller.close().catchError((_) {});
    await client.close();
    await server.stop();
    await http.close(force: true);
  });

  BidirectionalStreamCaller<RpcString, RpcString> open() {
    final c = BidirectionalStreamCaller<RpcString, RpcString>(
      transport: client,
      serviceName: 'Svc',
      methodName: 'echo',
      requestCodec: _codec,
      responseCodec: _codec,
    );
    c.responses.listen((_) {}, onError: (Object _) {});
    return c;
  }

  Future<String> live() async {
    final r = await caller
        .unaryRequest<RpcString, RpcString>(
          serviceName: 'Svc',
          methodName: 'live',
          request: '?'.rpc,
          requestCodec: _codec,
          responseCodec: _codec,
        )
        .timeout(const Duration(seconds: 10));
    return r.value;
  }

  // Polls rather than sleeping once: the teardown is the peer's, so on a loaded
  // machine it is late rather than absent, while the leak this guards against
  // never clears at all. Asking over the wire doubles as the connection check.
  Future<void> expectNoneLive() async {
    final deadline = DateTime.now().add(const Duration(seconds: 15));
    var last = '?';
    while (DateTime.now().isBefore(deadline)) {
      last = await live();
      if (last == '0') return;
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    fail('$last handlers are still waiting on request streams that ended');
  }

  test('WITNESS: an erroring request sink stops the handler', () async {
    for (var i = 0; i < calls; i++) {
      final c = open();
      await c.requestSink.addStream(_twoThenError()).catchError((Object _) {});
      await Future<void>.delayed(const Duration(milliseconds: 30));
    }
    await expectNoneLive();
  });

  test('GUARD: the healthy half-close is unchanged', () async {
    for (var i = 0; i < calls; i++) {
      final c = open();
      c.requestSink.add('a'.rpc);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      await c.requestSink.close();
      await Future<void>.delayed(const Duration(milliseconds: 30));
    }
    await expectNoneLive();
  });
}
