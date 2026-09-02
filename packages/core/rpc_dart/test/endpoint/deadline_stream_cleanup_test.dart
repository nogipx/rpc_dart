// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// _onDeadlineExceeded cancelled the handler's token and stopped there. That is
// only a REQUEST to stop, and Dart cannot preempt a handler that ignores it, so
// a handler still running when its deadline passed pinned its stream state and
// its responder forever.
//
// Found by running every call shape through every outcome and checking that all
// per-call bookkeeping returns to baseline. 30 calls each:
//
//   mode=ok    all four shapes -> open=0  resp=0
//   mode=err   all four shapes -> open=0  resp=0
//   mode=slow  all four shapes -> open=30 resp=30   <- one leaked per call
//
// The counters never came back down. With RpcSecurityPolicy.maxActiveStreams
// enforced, a slow handler turns that leak into a hard outage once it reaches
// the ceiling (4096 by default) and the server starts refusing every new
// stream.

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

/// True once a handler has observed its cancellation token.
final Map<String, bool> _sawCancel = {};

final class _Contract extends RpcResponderContract {
  _Contract() : super('Svc');

  void _watch(String n, RpcContext? c) {
    c?.cancellationToken?.cancelled.then((_) => _sawCancel[n] = true);
  }

  @override
  void setup() {
    // Ignores its cancellation token entirely: the case the token alone
    // cannot handle.
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'stubborn',
      handler: (r, {RpcContext? context}) async {
        _watch('stubborn', context);
        await Completer<void>().future;
        return r;
      },
      requestCodec: _codec,
      responseCodec: _codec,
    );

    addServerStreamMethod<RpcString, RpcString>(
      methodName: 'stubbornStream',
      handler: (r, {RpcContext? context}) async* {
        _watch('stubbornStream', context);
        yield r;
        await Completer<void>().future;
      },
      requestCodec: _codec,
      responseCodec: _codec,
    );

    addUnaryMethod<RpcString, RpcString>(
      methodName: 'quick',
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

int _open(_Rig r) =>
    r.responder.collectEndpointMetrics()['openStreams']! as int;
int _responders(_Rig r) =>
    r.responder.collectEndpointMetrics()['activeResponders']! as int;

void main() {
  setUp(_sawCancel.clear);

  test('a handler that outlives its deadline does not leak', () async {
    final rig = _connect();
    const calls = 20;

    for (var i = 0; i < calls; i++) {
      try {
        await rig.caller.unaryRequest<RpcString, RpcString>(
          serviceName: 'Svc',
          methodName: 'stubborn',
          request: 'a'.rpc,
          requestCodec: _codec,
          responseCodec: _codec,
          context: RpcContext.withTimeout(const Duration(milliseconds: 50)),
        );
      } catch (_) {
        // Expected: the deadline ends the call.
      }
    }

    // Reclamation is deferred past the deadline on purpose; wait it out.
    await Future<void>.delayed(const Duration(seconds: 3));
    expect(
      _open(rig),
      0,
      reason: '${_open(rig)} of $calls stream states survived their deadline',
    );
    expect(_responders(rig), 0);

    await _teardown(rig);
  });

  test('the same holds for a streaming handler', () async {
    final rig = _connect();
    const calls = 20;

    for (var i = 0; i < calls; i++) {
      try {
        await rig.caller
            .serverStream<RpcString, RpcString>(
              serviceName: 'Svc',
              methodName: 'stubbornStream',
              request: 'a'.rpc,
              requestCodec: _codec,
              responseCodec: _codec,
              context: RpcContext.withTimeout(const Duration(milliseconds: 50)),
            )
            .toList();
      } catch (_) {}
    }

    await Future<void>.delayed(const Duration(seconds: 3));
    expect(_open(rig), 0, reason: '${_open(rig)} stream states survived');
    expect(_responders(rig), 0);

    await _teardown(rig);
  });

  test('the handler is still asked to stop first', () async {
    // Tearing the stream down must not replace the cooperative signal: a
    // handler that DOES watch its token still gets told.
    final rig = _connect();

    try {
      await rig.caller.unaryRequest<RpcString, RpcString>(
        serviceName: 'Svc',
        methodName: 'stubborn',
        request: 'a'.rpc,
        requestCodec: _codec,
        responseCodec: _codec,
        context: RpcContext.withTimeout(const Duration(milliseconds: 100)),
      );
    } catch (_) {}

    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(
      _sawCancel['stubborn'],
      isTrue,
      reason: 'the deadline no longer fires the handler cancellation token',
    );

    await _teardown(rig);
  });

  test('the caller still sees a deadline, not a server status', () async {
    // A DEADLINE_EXCEEDED trailer from the server would race the caller's own
    // deadline and change the exception type non-deterministically.
    final rig = _connect();

    await expectLater(
      rig.caller.unaryRequest<RpcString, RpcString>(
        serviceName: 'Svc',
        methodName: 'stubborn',
        request: 'a'.rpc,
        requestCodec: _codec,
        responseCodec: _codec,
        context: RpcContext.withTimeout(const Duration(milliseconds: 100)),
      ),
      throwsA(isA<RpcDeadlineExceededException>()),
    );

    await _teardown(rig);
  });

  test('a call that answers inside its deadline is unaffected', () async {
    final rig = _connect();

    for (var i = 0; i < 10; i++) {
      final r = await rig.caller.unaryRequest<RpcString, RpcString>(
        serviceName: 'Svc',
        methodName: 'quick',
        request: 'hi'.rpc,
        requestCodec: _codec,
        responseCodec: _codec,
        context: RpcContext.withTimeout(const Duration(seconds: 30)),
      );
      expect(r.value, 'hi');
    }

    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(_open(rig), 0);
    expect(
      _sawCancel['quick'],
      isNull,
      reason: 'a call inside its deadline must not be cancelled',
    );

    await _teardown(rig);
  });
}
