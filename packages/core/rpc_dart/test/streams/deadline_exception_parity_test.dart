// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// Measured across the four call shapes with a 600ms deadline and a handler
// that never produces:
//
//   unary   -> TimeoutException               after 613ms
//   server  -> RpcDeadlineExceededException   after 602ms
//   client  -> RpcDeadlineExceededException   after 603ms
//   bidi    -> RpcDeadlineExceededException   after 606ms
//
// Every shape honoured the deadline, and every shape propagated cancellation
// to the server handler. Only the exception type disagreed -- and unary, the
// most common shape, was the odd one out, reporting a dart:async
// TimeoutException that `on RpcDeadlineExceededException` does not catch.
//
// Unary was not even self-consistent: _checkContextBeforeCall throws
// RpcDeadlineExceededException when the deadline has ALREADY passed, while the
// response wait threw TimeoutException when the SAME deadline passed a moment
// later. Which type a caller had to catch depended on whether their deadline
// expired just before the call or just after it.
//
// An explicit `timeout:` argument to UnaryCaller.call() is NOT a deadline and
// still yields TimeoutException.

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

/// Set when a handler's cancellation token fires.
final Map<String, bool> _tokenFired = {};

/// Set when a handler actually starts. A deadline can expire before the
/// responder dispatches, in which case the call is correctly abandoned and the
/// handler never runs at all -- so "the token fired" is only assertable when
/// there was a handler to observe it.
final Map<String, bool> _started = {};

final class _Contract extends RpcResponderContract {
  _Contract() : super('Svc');

  void _watch(String name, RpcContext? ctx) {
    _started[name] = true;
    ctx?.cancellationToken?.cancelled.then((_) => _tokenFired[name] = true);
  }

  @override
  void setup() {
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'unary',
      handler: (r, {RpcContext? context}) async {
        _watch('unary', context);
        await Completer<void>().future;
        return r;
      },
      requestCodec: _codec,
      responseCodec: _codec,
    );

    addServerStreamMethod<RpcString, RpcString>(
      methodName: 'server',
      handler: (r, {RpcContext? context}) async* {
        _watch('server', context);
        await Completer<void>().future;
      },
      requestCodec: _codec,
      responseCodec: _codec,
    );

    addClientStreamMethod<RpcString, RpcString>(
      methodName: 'client',
      handler: (reqs, {RpcContext? context}) async {
        _watch('client', context);
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
        _watch('bidi', context);
        await Completer<void>().future;
      },
      requestCodec: _codec,
      responseCodec: _codec,
    );

    addUnaryMethod<RpcString, RpcString>(
      methodName: 'echo',
      handler: (r, {RpcContext? context}) async => r,
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

Stream<RpcString> _oneRequest() {
  final c = StreamController<RpcString>();
  c.add('a'.rpc);
  unawaited(c.close());
  return c.stream;
}

/// Drives [shape] with [ctx] and returns whatever it threw.
Future<Object?> _drive(_Rig rig, String shape, RpcContext? ctx) async {
  try {
    switch (shape) {
      case 'unary':
        await rig.caller.unaryRequest<RpcString, RpcString>(
          serviceName: 'Svc',
          methodName: 'unary',
          request: 'a'.rpc,
          requestCodec: _codec,
          responseCodec: _codec,
          context: ctx,
        );
      case 'server':
        await rig.caller
            .serverStream<RpcString, RpcString>(
              serviceName: 'Svc',
              methodName: 'server',
              request: 'a'.rpc,
              requestCodec: _codec,
              responseCodec: _codec,
              context: ctx,
            )
            .toList();
      case 'client':
        await rig.caller.clientStream<RpcString, RpcString>(
          serviceName: 'Svc',
          methodName: 'client',
          requestCodec: _codec,
          responseCodec: _codec,
          context: ctx,
        )(_oneRequest());
      case 'bidi':
        await rig.caller
            .bidirectionalStream<RpcString, RpcString>(
              serviceName: 'Svc',
              methodName: 'bidi',
              requests: _oneRequest(),
              requestCodec: _codec,
              responseCodec: _codec,
              context: ctx,
            )
            .toList();
    }
  } catch (e) {
    return e;
  }
  return null;
}

void main() {
  setUp(() {
    _tokenFired.clear();
    _started.clear();
  });

  group('every shape reports an expired deadline the same way', () {
    for (final shape in ['unary', 'server', 'client', 'bidi']) {
      test(shape, () async {
        final rig = _connect();
        final sw = Stopwatch()..start();

        final thrown =
            await _drive(
              rig,
              shape,
              RpcContext.withTimeout(const Duration(milliseconds: 500)),
            ).timeout(
              const Duration(seconds: 5),
              onTimeout: () => fail('$shape ignored its deadline'),
            );
        sw.stop();

        expect(
          thrown,
          isA<RpcDeadlineExceededException>(),
          reason:
              '$shape reported its deadline as ${thrown.runtimeType}; '
              '`on RpcDeadlineExceededException` would miss it',
        );
        expect(
          sw.elapsedMilliseconds,
          lessThan(3000),
          reason: '$shape ran well past its 500ms deadline',
        );

        // Parity that already held, pinned so it keeps holding -- but only
        // meaningful if the handler ever started. A deadline can expire before
        // the responder dispatches (this suite runs ~1000 tests in parallel),
        // and such a call is now correctly abandoned rather than dispatched
        // late, so the handler legitimately never runs and never sees a token.
        // Asserting unconditionally made this flake roughly 1 run in 10.
        await Future<void>.delayed(const Duration(milliseconds: 250));
        if (_started[shape] == true) {
          expect(
            _tokenFired[shape],
            isTrue,
            reason: '$shape started its handler but never told it to stop',
          );
        }

        await _teardown(rig);
      });
    }
  });

  test('unary matches itself before and during the call', () async {
    // The pre-flight check has always thrown RpcDeadlineExceededException for
    // an already-expired deadline; the response wait threw TimeoutException
    // for the same deadline expiring a moment later.
    final rig = _connect();

    final expired = RpcContext.withDeadline(
      DateTime.now().subtract(const Duration(seconds: 1)),
    );
    final before = await _drive(rig, 'unary', expired);
    expect(before, isA<RpcDeadlineExceededException>());

    final during = await _drive(
      rig,
      'unary',
      RpcContext.withTimeout(const Duration(milliseconds: 300)),
    );
    expect(
      during.runtimeType,
      before.runtimeType,
      reason: 'the same deadline reports differently depending on timing',
    );

    await _teardown(rig);
  });

  group('unchanged behaviour', () {
    test('an explicit timeout: argument is not a deadline', () async {
      // UnaryCaller.call(timeout:) is a caller-supplied bound, not an RPC
      // deadline, and keeps TimeoutException.
      final (client, server) = RpcChannelTransport.pair();
      final caller = RpcCallerEndpoint(transport: client);
      final responder = RpcResponderEndpoint(transport: server);
      responder.registerServiceContract(_Contract());
      responder.start();

      final unary = UnaryCaller<RpcString, RpcString>(
        transport: client,
        serviceName: 'Svc',
        methodName: 'unary',
        requestCodec: _codec,
        responseCodec: _codec,
      );

      await expectLater(
        unary.call('a'.rpc, timeout: const Duration(milliseconds: 300)),
        throwsA(isA<TimeoutException>()),
      );

      await caller.close();
      await responder.close();
      await client.close();
      await server.close();
    });

    test('a call that answers inside its deadline is unaffected', () async {
      final rig = _connect();
      final result = await rig.caller.unaryRequest<RpcString, RpcString>(
        serviceName: 'Svc',
        methodName: 'echo',
        request: 'hello'.rpc,
        requestCodec: _codec,
        responseCodec: _codec,
        context: RpcContext.withTimeout(const Duration(seconds: 30)),
      );
      expect(result.value, 'hello');
      await _teardown(rig);
    });
  });
}
