// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// CallProcessor._setupDeadlineMonitoring surfaces the deadline as an error on
// the response stream, because -- as its own doc says -- a bare close is
// indistinguishable from the server having finished, so the consumer would get
// a silently truncated stream instead.
//
// It gated that on `context.isExpired`, which is `clock().isAfter(deadline)`,
// STRICT. The scope's timer is armed for `deadline.difference(clock())`, and
// Timer and DateTime do not share a clock source -- so when the timer fires,
// `now` can be exactly the deadline or a hair short of it. `isExpired` was then
// false, the disposer returned, and the controllers closed with no error: the
// exact failure the disposer exists to prevent.
//
// It surfaced as a ~1-in-20 flake under load, reproducible at `dart test -j 24`
// within a few runs, and diagnosed with:
//
//   DIAG bidi: null after 500ms started=true fired=null pending=0 open=1
//
// -- the stream ended at exactly the deadline, cleanly, with no error.
//
// These tests pin the boundary DETERMINISTICALLY by freezing the context clock
// at exactly the deadline, which is the instant the race turns on: isExpired is
// false there, while the scope's remaining time is zero so it closes at once.

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

final class _Contract extends RpcResponderContract {
  _Contract() : super('Svc');

  @override
  void setup() {
    addServerStreamMethod<RpcString, RpcString>(
      methodName: 'server',
      handler: (r, {RpcContext? context}) async* {
        await Completer<void>().future;
      },
      requestCodec: _codec,
      responseCodec: _codec,
    );
    addClientStreamMethod<RpcString, RpcString>(
      methodName: 'client',
      handler: (reqs, {RpcContext? context}) async {
        await for (final _ in reqs) {}
        await Completer<void>().future;
        return 'x'.rpc;
      },
      requestCodec: _codec,
      responseCodec: _codec,
    );
    addBidirectionalMethod<RpcString, RpcString>(
      methodName: 'bidi',
      handler: (reqs, {RpcContext? context}) async* {
        await Completer<void>().future;
      },
      requestCodec: _codec,
      responseCodec: _codec,
    );
    addServerStreamMethod<RpcString, RpcString>(
      methodName: 'quick',
      handler: (r, {RpcContext? context}) async* {
        yield r;
      },
      requestCodec: _codec,
      responseCodec: _codec,
    );
  }
}

typedef _Rig = ({
  RpcChannelTransport client,
  RpcChannelTransport server,
  RpcCallerEndpoint caller,
  RpcResponderEndpoint responder,
});

_Rig _connect() {
  final (client, server) = RpcChannelTransport.pair();
  final caller = RpcCallerEndpoint(transport: client);
  final responder = RpcResponderEndpoint(transport: server);
  responder.registerServiceContract(_Contract());
  responder.start();
  return (client: client, server: server, caller: caller, responder: responder);
}

Future<void> _teardown(_Rig r) async {
  await r.caller.close();
  await r.responder.close();
  await r.client.close();
  await r.server.close();
}

/// A context whose clock is frozen at EXACTLY its deadline.
///
/// `isExpired` is false there (the comparison is strict), while the scope's
/// remaining time is zero so it closes immediately -- precisely the state the
/// timer lands in when it fires on the boundary.
RpcContext _atDeadline() {
  final now = DateTime.now();
  return RpcContext.withDeadline(now).withClock(() => now);
}

Stream<RpcString> _one() {
  final c = StreamController<RpcString>();
  c.add('a'.rpc);
  unawaited(c.close());
  return c.stream;
}

void main() {
  test('the boundary state really is the tricky one', () {
    // If this stops holding, these tests stop testing the boundary.
    final ctx = _atDeadline();
    expect(ctx.isExpired, isFalse, reason: 'isAfter is strict');
    expect(ctx.remainingTime, Duration.zero, reason: 'no time left');
  });

  test('a server stream reports the deadline, not a clean close', () async {
    final rig = _connect();
    await expectLater(
      rig.caller
          .serverStream<RpcString, RpcString>(
            serviceName: 'Svc',
            methodName: 'server',
            request: 'a'.rpc,
            requestCodec: _codec,
            responseCodec: _codec,
            context: _atDeadline(),
          )
          .toList()
          .timeout(const Duration(seconds: 5)),
      throwsA(isA<RpcDeadlineExceededException>()),
    );
    await _teardown(rig);
  });

  test('a bidirectional stream reports the deadline', () async {
    final rig = _connect();
    await expectLater(
      rig.caller
          .bidirectionalStream<RpcString, RpcString>(
            serviceName: 'Svc',
            methodName: 'bidi',
            requests: _one(),
            requestCodec: _codec,
            responseCodec: _codec,
            context: _atDeadline(),
          )
          .toList()
          .timeout(const Duration(seconds: 5)),
      throwsA(isA<RpcDeadlineExceededException>()),
    );
    await _teardown(rig);
  });

  test('a client stream reports the deadline', () async {
    final rig = _connect();
    await expectLater(
      rig.caller
          .clientStream<RpcString, RpcString>(
            serviceName: 'Svc',
            methodName: 'client',
            requestCodec: _codec,
            responseCodec: _codec,
            context: _atDeadline(),
          )(_one())
          .timeout(const Duration(seconds: 5)),
      throwsA(isA<RpcDeadlineExceededException>()),
    );
    await _teardown(rig);
  });

  group('unchanged behaviour', () {
    test('a call with time left is not reported as a deadline', () async {
      final rig = _connect();
      final got = await rig.caller
          .serverStream<RpcString, RpcString>(
            serviceName: 'Svc',
            methodName: 'quick',
            request: 'a'.rpc,
            requestCodec: _codec,
            responseCodec: _codec,
            context: RpcContext.withTimeout(const Duration(seconds: 30)),
          )
          .map((r) => r.value)
          .toList()
          .timeout(const Duration(seconds: 5));
      expect(got, ['a']);
      await _teardown(rig);
    });

    test('a cancelled call reports cancellation, not a deadline', () async {
      // The scope auto-closes for two reasons; this is the other one, and it
      // must still be surfaced as a cancellation.
      final rig = _connect();
      final token = RpcCancellationToken();

      final future = rig.caller
          .serverStream<RpcString, RpcString>(
            serviceName: 'Svc',
            methodName: 'server',
            request: 'a'.rpc,
            requestCodec: _codec,
            responseCodec: _codec,
            context: RpcContext.withTimeout(
              const Duration(seconds: 30),
            ).withCancellation(token),
          )
          .toList();

      await Future<void>.delayed(const Duration(milliseconds: 100));
      token.cancel('user quit');

      await expectLater(
        future.timeout(const Duration(seconds: 5)),
        throwsA(isA<RpcCancelledException>()),
      );
      await _teardown(rig);
    });
  });
}
