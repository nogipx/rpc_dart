// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// ServerStreamResponder consumed the user handler's stream with a bare
// `await for`, whose implicit subscription nothing could reach. close() had no
// way to stop it, and _processor.send() returns silently once the processor is
// inactive rather than throwing, so the loop's error `break` never fired
// either. A long-lived handler therefore kept producing FOREVER after the
// client cancelled -- burning CPU and pinning everything the generator
// captured, for the life of the server process. Three cancelled calls left
// three generators spinning (measured: 217 extra iterations in 500ms).
//
// The responder now owns the handler subscription and cancels it on close.

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

/// Counts every loop iteration of the infinite handlers below.
int _ticks = 0;

final class _InfiniteContract extends RpcResponderContract {
  _InfiniteContract() : super('Svc');

  @override
  void setup() {
    addServerStreamMethod<RpcString, RpcString>(
      methodName: 'inf',
      handler: (request, {RpcContext? context}) async* {
        while (true) {
          _ticks++;
          yield 'v'.rpc;
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
      },
      requestCodec: _codec,
      responseCodec: _codec,
    );

    addBidirectionalMethod<RpcString, RpcString>(
      methodName: 'infBidi',
      handler: (requests, {RpcContext? context}) async* {
        while (true) {
          _ticks++;
          yield 'v'.rpc;
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
      },
      requestCodec: _codec,
      responseCodec: _codec,
    );
  }
}

void main() {
  test('a cancelled server stream stops the handler generator', () async {
    _ticks = 0;
    final (client, server) = RpcChannelTransport.pair();
    final caller = RpcCallerEndpoint(transport: client);
    final responder = RpcResponderEndpoint(transport: server);
    responder.registerServiceContract(_InfiniteContract());
    responder.start();

    // take(1) cancels the subscription after the first response, abandoning an
    // otherwise infinite handler.
    for (var i = 0; i < 3; i++) {
      final got = await caller
          .serverStream<RpcString, RpcString>(
            serviceName: 'Svc',
            methodName: 'inf',
            request: 'x'.rpc,
            requestCodec: _codec,
            responseCodec: _codec,
          )
          .take(1)
          .toList();
      expect(got, hasLength(1));
    }

    // Let the cancellations settle. An async* generator resumes once past its
    // suspension point before terminating, so a small wind-down is expected.
    await Future<void>.delayed(const Duration(milliseconds: 400));
    final settled = _ticks;

    // Nothing may run after that: the generators must be gone, not merely idle.
    await Future<void>.delayed(const Duration(milliseconds: 600));
    expect(
      _ticks,
      settled,
      reason:
          'handler generators kept producing after the client cancelled '
          '(was $settled, now $_ticks)',
    );

    await caller.close();
    await responder.close();
    await client.close();
    await server.close();
  });

  test(
    'cancelling a bidirectional stream returns and stops the handler',
    () async {
      _ticks = 0;
      final (client, server) = RpcChannelTransport.pair();
      final caller = RpcCallerEndpoint(transport: client);
      final responder = RpcResponderEndpoint(transport: server);
      responder.registerServiceContract(_InfiniteContract());
      responder.start();

      // A request stream the caller deliberately leaves OPEN -- the realistic
      // bidi shape, and the one that used to deadlock cancel(): `requests` is a
      // suspended async* middleware chain whose cancellation cannot complete
      // until the upstream produces again.
      final requests = StreamController<RpcString>();
      requests.add('a'.rpc);

      var received = 0;
      final sub = caller
          .bidirectionalStream<RpcString, RpcString>(
            serviceName: 'Svc',
            methodName: 'infBidi',
            requests: requests.stream,
            requestCodec: _codec,
            responseCodec: _codec,
          )
          .listen((_) => received++);

      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(received, greaterThan(0));

      // Must not deadlock: this used to hang forever.
      await sub.cancel().timeout(
        const Duration(seconds: 5),
        onTimeout: () => fail('bidirectional cancel() deadlocked'),
      );

      await Future<void>.delayed(const Duration(milliseconds: 300));
      final settled = _ticks;
      await Future<void>.delayed(const Duration(milliseconds: 600));
      expect(
        _ticks,
        settled,
        reason:
            'bidi handler kept producing after the client cancelled '
            '(was $settled, now $_ticks)',
      );

      await requests.close();
      await caller.close();
      await responder.close();
      await client.close();
      await server.close();
    },
  );
}
