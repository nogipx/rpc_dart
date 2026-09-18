// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// A bidi caller whose request sink ERRORS, over real HTTP/2. Here the notice is
// a trailing HEADERS frame on a stream whose DATA has already flowed, which is
// the route least like the other two.
//
// The server reports through a unary call on the SAME connection.
//
// Measured with the core notice ablated and restored:
//
//   erroring (ablated)   5 handlers still live      control   0
//   erroring (fixed)     0                          control   0

@TestOn('vm')
library;

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_http2/rpc_dart_http2.dart';
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

  late RpcHttp2Server server;
  late RpcHttp2CallerTransport client;
  late RpcCallerEndpoint caller;

  setUp(() async {
    server = RpcHttp2Server(
      host: '127.0.0.1',
      port: 0,
      onEndpointCreated: (e) => e.registerServiceContract(_Svc()),
    );
    await server.start();
    client = await RpcHttp2CallerTransport.connect(
      host: '127.0.0.1',
      port: server.port,
      logger: LogScope.noop,
    );
    caller = RpcCallerEndpoint(transport: client);
  });

  tearDown(() async {
    await caller.close().catchError((_) {});
    await client.close();
    await server.stop();
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
  // never clears at all. Asking over the wire doubles as the connection check --
  // ablating the close made THIS call fail with UNAVAILABLE.
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

  test(
    'WITNESS: an erroring request sink stops the handler',
    () async {
      for (var i = 0; i < calls; i++) {
        final c = open();
        await c.requestSink
            .addStream(_twoThenError())
            .catchError((Object _) {});
        await Future<void>.delayed(const Duration(milliseconds: 30));
      }
      await expectNoneLive();
    },
    // B-53's REMAINING half, and round 388 sharpened which one. 388 fixed the
    // ordinary case — a consumer letting go after the half-close, with the
    // trailer in flight — by leaving that reset to package:http2's own ordered
    // one. This path is the other case: the producer ERRORS, so the stream was
    // never half-closed, http2 sends nothing, and rpc_dart's own RST_STREAM is
    // the only signal that stops the handler. Sent while the server is
    // mid-response it still costs the connection. Unskip when that half lands.
    skip: 'B-53: an abort on a stream we have not half-closed, mid-response',
  );

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
