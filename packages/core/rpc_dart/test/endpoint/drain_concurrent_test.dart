// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// drain() guarded re-entry with `if (_respIsDraining) return;`, so every
// caller after the first got a Future that completed immediately -- while
// streams were still in flight. Its own doc promises the opposite: "completes
// when all active streams have finished, or when timeout expires".
//
// Measured before the fix, with one long server stream open:
//     SECOND drain returned after 1ms    with openStreams=1
//     FIRST  drain returned after 5015ms with openStreams=0
//
// RpcApp.stop() reaches drain() through Future.wait over every endpoint, so
// two shutdown paths racing (a signal handler and an explicit stop) is enough
// for a caller to walk straight past the drain and tear down what it was
// protecting.

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

final class _SlowContract extends RpcResponderContract {
  _SlowContract() : super('Svc');

  @override
  void setup() {
    addServerStreamMethod<RpcString, RpcString>(
      methodName: 'slow',
      handler: (request, {RpcContext? context}) async* {
        for (var i = 0; i < 100; i++) {
          yield '$i'.rpc;
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
      },
      requestCodec: _codec,
      responseCodec: _codec,
    );
  }
}

void main() {
  late RpcChannelTransport client;
  late RpcChannelTransport server;
  late RpcCallerEndpoint caller;
  late RpcResponderEndpoint responder;

  setUp(() {
    (client, server) = RpcChannelTransport.pair();
    caller = RpcCallerEndpoint(transport: client);
    responder = RpcResponderEndpoint(transport: server);
    responder.registerServiceContract(_SlowContract());
    responder.start();
  });

  tearDown(() async {
    await caller.close();
    await responder.close();
    await client.close();
    await server.close();
  });

  int openStreams() =>
      responder.collectResponderMetrics()['openStreams']! as int;

  Future<StreamSubscription<RpcString>> openSlowStream() async {
    final sub = caller
        .serverStream<RpcString, RpcString>(
          serviceName: 'Svc',
          methodName: 'slow',
          request: 'x'.rpc,
          requestCodec: _codec,
          responseCodec: _codec,
        )
        .listen((_) {});
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(openStreams(), 1, reason: 'the stream should be live');
    return sub;
  }

  test('a concurrent drain waits for the same completion', () async {
    final sub = await openSlowStream();

    // Both start while the stream is live; both must observe it finished.
    final first = responder.drain(timeout: const Duration(seconds: 3));
    final second = responder.drain(timeout: const Duration(seconds: 3));

    await second;
    expect(
      openStreams(),
      0,
      reason: 'the second caller returned while a stream was still active',
    );

    await first;
    expect(openStreams(), 0);
    await sub.cancel();
  });

  test('a drain started after one finished stays settled', () async {
    final sub = await openSlowStream();

    await responder.drain(timeout: const Duration(seconds: 3));
    expect(openStreams(), 0);

    // A later call must not hang or reopen anything.
    await responder
        .drain(timeout: const Duration(seconds: 3))
        .timeout(const Duration(seconds: 1));
    expect(responder.isDraining, isTrue);
    await sub.cancel();
  });

  test('drain still reports finished when nothing is in flight', () async {
    await responder
        .drain(timeout: const Duration(seconds: 3))
        .timeout(const Duration(seconds: 2));
    expect(openStreams(), 0);
    expect(responder.isDraining, isTrue);
  });
}
