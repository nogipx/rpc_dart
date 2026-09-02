// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// Companion to deadline_boundary_test.dart. That one covers the deadline TIMER
// landing on the boundary; this one covers the peer CLOSING the stream there.
//
// Both paths answer the same question -- "did my deadline pass?" -- and both
// originally asked it with `context.isExpired`, which is
// `clock().isAfter(deadline)`, STRICT. So it is FALSE at the exact instant the
// deadline lands, while `remainingTime` is already Duration.zero. The two
// contradict each other on the boundary.
//
// The path here is the stream COLLAPSING -- the transport ending it with no
// trailer, as happens when a connection drops. A clean END_STREAM is different:
// it carries a status, and _handleResponse closes the controller there, so a
// call that genuinely succeeded is never reinterpreted (guarded below).
//
// Pinned deterministically with a MUTABLE fake clock: the call starts with time
// to spare (so the scope's timer stays armed and does not decide the outcome),
// then the clock is advanced to exactly the deadline before the peer closes.

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

/// Released to let a handler finish, closing its stream from the server side.
Completer<void> _release = Completer<void>();

final class _Contract extends RpcResponderContract {
  _Contract() : super('Svc');

  @override
  void setup() {
    // Emits nothing and ends when released: a clean server-side close.
    addServerStreamMethod<RpcString, RpcString>(
      methodName: 'endsQuietly',
      handler: (r, {RpcContext? context}) async* {
        await _release.future;
      },
      requestCodec: _codec,
      responseCodec: _codec,
    );

    addBidirectionalMethod<RpcString, RpcString>(
      methodName: 'bidiEndsQuietly',
      handler: (reqs, {RpcContext? context}) async* {
        await _release.future;
      },
      requestCodec: _codec,
      responseCodec: _codec,
    );

    addServerStreamMethod<RpcString, RpcString>(
      methodName: 'echoes',
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

/// A context whose clock this test drives by hand.
({RpcContext ctx, DateTime deadline, void Function() jumpToDeadline}) _fake() {
  final start = DateTime.now();
  final deadline = start.add(const Duration(seconds: 30));
  var now = start;
  final ctx = RpcContext.withDeadline(deadline).withClock(() => now);
  return (
    ctx: ctx,
    deadline: deadline,
    // EXACTLY the deadline: isExpired is false here, remainingTime is zero.
    jumpToDeadline: () => now = deadline,
  );
}

Stream<RpcString> _one() {
  final c = StreamController<RpcString>();
  c.add('a'.rpc);
  unawaited(c.close());
  return c.stream;
}

void main() {
  setUp(() => _release = Completer<void>());
  tearDown(() {
    if (!_release.isCompleted) _release.complete();
  });

  test('the boundary state is still the contradictory one', () {
    final f = _fake();
    f.jumpToDeadline();
    expect(f.ctx.isExpired, isFalse, reason: 'isAfter is strict');
    expect(f.ctx.remainingTime, Duration.zero, reason: 'no time left');
  });

  test(
    'a server stream collapsing on the boundary reports the deadline',
    () async {
      final rig = _connect();
      final f = _fake();

      final result = rig.caller
          .serverStream<RpcString, RpcString>(
            serviceName: 'Svc',
            methodName: 'endsQuietly',
            request: 'a'.rpc,
            requestCodec: _codec,
            responseCodec: _codec,
            context: f.ctx,
          )
          .toList();

      await Future<void>.delayed(const Duration(milliseconds: 100));
      f.jumpToDeadline();
      // The stream ends with no trailer, exactly on the boundary.
      await rig.server.close();

      await expectLater(
        result.timeout(const Duration(seconds: 5)),
        throwsA(isA<RpcDeadlineExceededException>()),
      );
      await rig.caller.close();
      await rig.client.close();
    },
  );

  test(
    'a bidi stream collapsing on the boundary reports the deadline',
    () async {
      final rig = _connect();
      final f = _fake();

      final result = rig.caller
          .bidirectionalStream<RpcString, RpcString>(
            serviceName: 'Svc',
            methodName: 'bidiEndsQuietly',
            requests: _one(),
            requestCodec: _codec,
            responseCodec: _codec,
            context: f.ctx,
          )
          .toList();

      await Future<void>.delayed(const Duration(milliseconds: 100));
      f.jumpToDeadline();
      await rig.server.close();

      await expectLater(
        result.timeout(const Duration(seconds: 5)),
        throwsA(isA<RpcDeadlineExceededException>()),
      );
      await rig.caller.close();
      await rig.client.close();
    },
  );

  group('unchanged behaviour', () {
    test('a collapse with time left is NOT reported as a deadline', () async {
      // Same collapse, but the clock never reaches the deadline.
      final rig = _connect();
      final f = _fake();

      final result = rig.caller
          .serverStream<RpcString, RpcString>(
            serviceName: 'Svc',
            methodName: 'endsQuietly',
            request: 'a'.rpc,
            requestCodec: _codec,
            responseCodec: _codec,
            context: f.ctx,
          )
          .toList();

      await Future<void>.delayed(const Duration(milliseconds: 100));
      await rig.server.close();

      Object? thrown;
      try {
        await result.timeout(const Duration(seconds: 5));
      } catch (e) {
        thrown = e;
      }
      expect(
        thrown,
        isNot(isA<RpcDeadlineExceededException>()),
        reason: 'a collapse before the deadline is not a deadline',
      );
      await rig.caller.close();
      await rig.client.close();
    });

    test('a call that SUCCEEDS on the boundary stays a success', () async {
      // A clean END_STREAM carries a status and must never be reinterpreted,
      // even when the deadline lands at the same instant.
      final rig = _connect();
      final f = _fake();

      final result = rig.caller
          .serverStream<RpcString, RpcString>(
            serviceName: 'Svc',
            methodName: 'endsQuietly',
            request: 'a'.rpc,
            requestCodec: _codec,
            responseCodec: _codec,
            context: f.ctx,
          )
          .toList();

      await Future<void>.delayed(const Duration(milliseconds: 100));
      f.jumpToDeadline();
      _release.complete(); // clean finish, right on the boundary

      expect(
        await result.timeout(const Duration(seconds: 5)),
        isEmpty,
        reason: 'a successful call must not become a deadline error',
      );
      await _teardown(rig);
    });

    test('a normal response inside the deadline still arrives', () async {
      final rig = _connect();
      final f = _fake();

      final got = await rig.caller
          .serverStream<RpcString, RpcString>(
            serviceName: 'Svc',
            methodName: 'echoes',
            request: 'hi'.rpc,
            requestCodec: _codec,
            responseCodec: _codec,
            context: f.ctx,
          )
          .map((r) => r.value)
          .toList()
          .timeout(const Duration(seconds: 5));

      expect(got, ['hi']);
      await _teardown(rig);
    });
  });
}
