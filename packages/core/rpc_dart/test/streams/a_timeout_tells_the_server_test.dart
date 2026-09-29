// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// A caller that gives up on a timeout released its stream id and told the server
// NOTHING, so the handler ran on for a caller that was already gone — the same
// defect the cancellation-token path was given a fix for, on the neighbouring
// ending.
//
// Measured with no deadline set, a handler that never answers, and the caller's
// own hidden 60 s fallback:
//
//                  before                      after
//   unary          cancelled=0 after 60.0s     cancelled=1
//   clientStream   cancelled=0 after 60.0s     cancelled=1
//   serverStream   cancelled=0 after 65.0s     cancelled=0   <- nothing bounds it
//
// The control is the SAME shapes with a real deadline, which already notified
// (the call scope does it) and reported `RpcDeadlineExceededException`:
//
//   unary/clientStream/serverStream, deadline 500ms: cancelled=1, grpc-timeout sent
//
// The serverStream row is untouched on purpose: it has no bound at all, which is
// a policy question left in B-107 rather than a defect this round invented an
// answer to.
//
// Driven here through `UnaryCaller.call(timeout:)` and a short wait rather than
// the 60 s fallback: the explicit argument takes the SAME `onTimeout` path, and
// it is the path that keeps `TimeoutException`, so a deadline would have hidden
// the fix behind machinery that already worked.

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

typedef _Rig = ({
  RpcChannelTransport client,
  RpcCallerEndpoint caller,
  int Function() cancels,
});

Future<_Rig> _rig() async {
  var cancels = 0;
  final (client, server) = RpcChannelTransport.pair();
  final responder = RpcResponderEndpoint(transport: server)
    ..registerServiceContract(_Svc(() => cancels++)..setup())
    ..start();
  final caller = RpcCallerEndpoint(transport: client);
  addTearDown(() async {
    await caller.close();
    await responder.close();
  });
  return (client: client, caller: caller, cancels: () => cancels);
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
    'WITNESS: a unary timeout tells the server',
    () async {
      final rig = await _rig();
      final unary = UnaryCaller<RpcString, RpcString>(
        transport: rig.client,
        serviceName: 'Svc',
        methodName: 'never',
        requestCodec: _codec,
        responseCodec: _codec,
      );

      await expectLater(
        unary.call('a'.rpc, timeout: const Duration(milliseconds: 300)),
        throwsA(isA<TimeoutException>()),
      );
      await _awaitCancel(rig.cancels);

      expect(
        rig.cancels(),
        1,
        reason:
            'the caller gave up and released the id without a word, so the '
            'handler runs on for a caller that is already gone',
      );
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );

  // NOT a witness for the client-stream half, and it is worth saying why rather
  // than leaving it looking like one.
  //
  // `ClientStreamCaller` takes its bound from the context alone, so the only way
  // to reach its `onTimeout` quickly is a deadline — and on the deadline path the
  // call SCOPE already cancels the handler, which is what the probe's control
  // arms showed (`cancelled=1` for every 500 ms deadline row, before any fix).
  // So this passes with the client-stream notice switched off, verified: it
  // measures machinery that already worked.
  //
  // The client-stream half's only witness is the probe, which waits out the
  // hidden 60 s fallback and reads `cancelled=0 -> 1`. Kept here as a GUARD of
  // what it does cover: the deadline path still notifies, and the notice added
  // beside it did not break that.
  test(
    'GUARD: a client-stream deadline still tells the server',
    () async {
      final rig = await _rig();
      final call = rig.caller.clientStream<RpcString, RpcString>(
        serviceName: 'Svc',
        methodName: 'neverUp',
        requestCodec: _codec,
        responseCodec: _codec,
        context: RpcContext.empty().withTimeout(
          const Duration(milliseconds: 300),
        ),
      );

      await expectLater(
        call(Stream.value('a'.rpc)),
        throwsA(isA<RpcStatusException>()),
      );
      await _awaitCancel(rig.cancels);

      expect(rig.cancels(), 1);
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );

  // GUARD: a call that ANSWERS must not send a cancellation notice. Without
  // this, "always notify" would pass both witnesses and tell the server every
  // successful call had been abandoned.
  test(
    'GUARD: a call that completes tells the server nothing',
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

  // GUARD: the exception TYPE is unchanged. An explicit `timeout:` argument is
  // not a deadline, and round 4xx's parity work turns on that distinction — the
  // notice must not have quietly converted it.
  test(
    'GUARD: an explicit timeout: still reports TimeoutException',
    () async {
      final rig = await _rig();
      final unary = UnaryCaller<RpcString, RpcString>(
        transport: rig.client,
        serviceName: 'Svc',
        methodName: 'never',
        requestCodec: _codec,
        responseCodec: _codec,
      );

      await expectLater(
        unary.call('a'.rpc, timeout: const Duration(milliseconds: 200)),
        throwsA(
          isA<TimeoutException>().having(
            (e) => e is RpcDeadlineExceededException,
            'is not a deadline exception',
            isFalse,
          ),
        ),
      );
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );
}
