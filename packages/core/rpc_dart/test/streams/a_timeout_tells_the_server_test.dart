// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// A caller whose deadline passes stops waiting AND tells the server, so the
// handler is cancelled instead of running on for a caller that is gone. A call
// that answers tells the server nothing.

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

final class _Svc extends RpcResponderContract {
  _Svc(this._onCancel) : super('Svc');

  final void Function() _onCancel;

  @override
  void setup() {
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'never',
      requestCodec: _codec,
      responseCodec: _codec,
      handler: (req, {context}) async {
        unawaited(
          context?.cancellationToken?.cancelled.then((_) => _onCancel()) ??
              Future<void>.value(),
        );
        // Never answers: the question is what the CALLER does and what it tells
        // the server on the way out.
        await Completer<void>().future;
        return 'unreachable'.rpc;
      },
    );
    addClientStreamMethod<RpcString, RpcString>(
      methodName: 'neverUp',
      requestCodec: _codec,
      responseCodec: _codec,
      handler: (requests, {context}) async {
        unawaited(
          context?.cancellationToken?.cancelled.then((_) => _onCancel()) ??
              Future<void>.value(),
        );
        await requests.toList();
        await Completer<void>().future;
        return 'unreachable'.rpc;
      },
    );
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'echo',
      requestCodec: _codec,
      responseCodec: _codec,
      handler: (req, {context}) async => 'echo:${req.value}'.rpc,
    );
  }
}

typedef _Rig = ({RpcCallerEndpoint caller, int Function() cancels});

Future<_Rig> _rig() async {
  var cancels = 0;
  final (client, server) = RpcChannelTransport.pair();
  final responder = RpcResponderEndpoint(transport: server)
    ..registerServiceContract(_Svc(() => cancels++))
    ..start();
  final caller = RpcCallerEndpoint(transport: client);
  addTearDown(() async {
    await caller.close();
    await responder.close();
  });
  return (caller: caller, cancels: () => cancels);
}

/// Polls rather than sleeps: the notice is sent unawaited and crosses a channel.
Future<void> _awaitCancel(int Function() cancels) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (cancels() < 1 && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

void main() {
  test(
    'a unary deadline tells the server',
    () async {
      final rig = await _rig();

      await expectLater(
        rig.caller.unaryRequest<RpcString, RpcString>(
          serviceName: 'Svc',
          methodName: 'never',
          request: 'a'.rpc,
          requestCodec: _codec,
          responseCodec: _codec,
          context: RpcContext.withTimeout(const Duration(milliseconds: 300)),
        ),
        throwsA(isA<RpcDeadlineExceededException>()),
      );
      await _awaitCancel(rig.cancels);

      expect(
        rig.cancels(),
        1,
        reason:
            'the caller gave up without a word, so the handler runs on for a '
            'caller that is already gone',
      );
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );

  test(
    'a client-stream deadline tells the server',
    () async {
      final rig = await _rig();
      await expectLater(
        rig.caller.clientStream<RpcString, RpcString>(
          serviceName: 'Svc',
          methodName: 'neverUp',
          requests: Stream.value('a'.rpc),
          requestCodec: _codec,
          responseCodec: _codec,
          context: RpcContext.withTimeout(const Duration(milliseconds: 300)),
        ),
        throwsA(isA<RpcStatusException>()),
      );
      await _awaitCancel(rig.cancels);

      expect(rig.cancels(), 1);
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );

  // GUARD: a call that ANSWERS must not send a cancellation notice. Without
  // this, "always notify" would pass both tests above and tell the server
  // every successful call had been abandoned.
  test(
    'GUARD a call that completes tells the server nothing',
    () async {
      final rig = await _rig();

      final reply = await rig.caller
          .unaryRequest<RpcString, RpcString>(
            serviceName: 'Svc',
            methodName: 'echo',
            request: 'hi'.rpc,
            requestCodec: _codec,
            responseCodec: _codec,
          )
          .timeout(const Duration(seconds: 5));
      expect(reply.value, 'echo:hi');

      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(
        rig.cancels(),
        0,
        reason: 'a successful call must not be reported as cancelled',
      );
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );
}
