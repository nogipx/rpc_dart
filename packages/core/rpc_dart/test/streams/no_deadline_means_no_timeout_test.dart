// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// Unary and client-stream calls carried a hidden 60 s bound for a call with no
// deadline; server-stream and bidi never had one. No `grpc-timeout` was sent for
// it, so the caller gave up while the server still believed the call was live —
// measured, the handler saw `cancelled=0` after the caller abandoned it at 60 s.
//
// A hidden limit the server never hears about is worse than no limit, so there is
// no implicit bound any more: no deadline means no timeout, which is what gRPC does
// and what the two streaming shapes already did.
//
// BREAKING: a caller relying on the 60 s to end a call that the server never
// answers now waits indefinitely. Set a deadline on the context.
//
// The 60 s arms live in the probe (`P-136`), not here: this file asserts what can be
// asserted in milliseconds, which is that the bound is GONE and that every explicit
// bound still fires.
//
// The measurements are in `.claude/loop/rounds/548`.

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

/// A responder that never answers, so only a client-side bound can end a call.
final class _Silent extends RpcResponderContract {
  _Silent() : super('Svc');

  @override
  void setup() {
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'never',
      requestCodec: _codec,
      responseCodec: _codec,
      handler: (req, {context}) async {
        await Completer<void>().future; // never
        return req;
      },
    );
    addClientStreamMethod<RpcString, RpcString>(
      methodName: 'upload',
      requestCodec: _codec,
      responseCodec: _codec,
      handler: (reqs, {context}) async {
        await reqs.drain<void>();
        await Completer<void>().future; // never
        return 'x'.rpc;
      },
    );
  }
}

typedef _Rig = ({RpcCallerEndpoint caller, List<String> sentTimeouts});

_Rig _rig() {
  final (clientTransport, serverTransport) = RpcChannelTransport.pair();

  // What the request actually declared, read off the wire rather than inferred:
  // the whole complaint about the old bound was that it was never sent.
  final sentTimeouts = <String>[];
  final sub = serverTransport.incomingMessages.listen((m) {
    final t = m.metadata?.getHeaderValue(RpcHeaders.grpcTimeout);
    if (m.methodPath != null) sentTimeouts.add(t ?? 'none');
  });

  final caller = RpcCallerEndpoint(transport: clientTransport);
  final responder = RpcResponderEndpoint(transport: serverTransport)
    ..registerServiceContract(_Silent())
    ..start();
  addTearDown(() async {
    await sub.cancel();
    await caller.close();
    await responder.close();
  });
  return (caller: caller, sentTimeouts: sentTimeouts);
}

void main() {
  test('WITNESS a unary call with no deadline is not bounded', () async {
    final rig = _rig();

    final call = rig.caller.unaryRequest<RpcString, RpcString>(
      serviceName: 'Svc',
      methodName: 'never',
      request: 'x'.rpc,
      requestCodec: _codec,
      responseCodec: _codec,
    );

    // Still pending is the whole assertion. It cannot prove "never" in a test —
    // the 60 s arm is P-136's job — but it does prove no bound was ARMED, because
    // any bound this code could arm would have to come from a deadline, and there
    // is none.
    expect(
      await call
          .then((_) => 'answered')
          .catchError((Object e) => '$e')
          .timeout(
            const Duration(milliseconds: 400),
            onTimeout: () => 'still waiting',
          ),
      'still waiting',
    );

    expect(
      rig.sentTimeouts,
      ['none'],
      reason: 'no deadline, so nothing to declare — and nothing was declared',
    );
  });

  test(
    'WITNESS a client-stream call with no deadline is not bounded',
    () async {
      final rig = _rig();

      final call = rig.caller.clientStream<RpcString, RpcString>(
        serviceName: 'Svc',
        methodName: 'upload',
        requestCodec: _codec,
        responseCodec: _codec,
      )(Stream.value('x'.rpc));

      expect(
        await call
            .then((_) => 'answered')
            .catchError((Object e) => '$e')
            .timeout(
              const Duration(milliseconds: 400),
              onTimeout: () => 'still waiting',
            ),
        'still waiting',
      );
    },
  );

  test(
    'GUARD an explicit deadline still ends the call, as a deadline',
    () async {
      final rig = _rig();

      Object? error;
      try {
        await rig.caller.unaryRequest<RpcString, RpcString>(
          serviceName: 'Svc',
          methodName: 'never',
          request: 'x'.rpc,
          requestCodec: _codec,
          responseCodec: _codec,
          context: RpcContext.empty().withTimeout(
            const Duration(milliseconds: 200),
          ),
        );
      } catch (e) {
        error = e;
      }

      expect(
        error,
        isA<RpcDeadlineExceededException>(),
        reason: 'removing the fallback must not remove the deadline path',
      );
      expect(
        rig.sentTimeouts.single,
        isNot('none'),
        reason: 'a real deadline IS declared to the server, which is the point',
      );
    },
  );

  test('GUARD a deadline still ends a client-stream call', () async {
    final rig = _rig();

    Object? error;
    try {
      await rig.caller.clientStream<RpcString, RpcString>(
        serviceName: 'Svc',
        methodName: 'upload',
        requestCodec: _codec,
        responseCodec: _codec,
        context: RpcContext.empty().withTimeout(
          const Duration(milliseconds: 200),
        ),
      )(Stream.value('x'.rpc));
    } catch (e) {
      error = e;
    }

    expect(error, isA<RpcDeadlineExceededException>());
  });
}
