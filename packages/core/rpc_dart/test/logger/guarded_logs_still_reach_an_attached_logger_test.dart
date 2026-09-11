// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// `if (_logger.isInternal)` must be a performance guard, not a mute button.
//
// Round 333 wrapped sixteen per-call `internal(...)` sites in the unary
// responder, because `internal` takes a String and so builds it even when the
// logger is `LogScope.noop` — measured, 35 discarded messages and 1566
// characters per round trip.
//
// The risk of that change is silent: if a guard reads a level the logger does
// not actually apply, the messages vanish for everyone and no existing test
// notices, because nothing else asserts that these particular lines are
// emitted. This is that assertion.
@TestOn('vm')
library;

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

final class _Svc extends RpcResponderContract {
  _Svc() : super('Svc');

  @override
  void setup() {
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'echo',
      handler: (r, {RpcContext? context}) async => r,
      requestCodec: _codec,
      responseCodec: _codec,
    );
  }
}

void main() {
  test(
    'a unary call still logs at internal level when one is attached',
    () async {
      final controller = LogController(minLevel: RpcLogLevel.internal);
      final seen = <String>[];
      final sub = controller.stream.listen((record) {
        if (record is LogEvent) seen.add(record.message);
      });

      final (clientT, serverT) = RpcChannelTransport.pair();
      final responder =
          RpcResponderEndpoint(transport: serverT, logger: controller)
            ..registerServiceContract(_Svc())
            ..start();
      final caller = RpcCallerEndpoint(transport: clientT, logger: controller);

      final reply = await caller.unaryRequest<RpcString, RpcString>(
        serviceName: 'Svc',
        methodName: 'echo',
        request: 'hi'.rpc,
        requestCodec: _codec,
        responseCodec: _codec,
      );
      expect(reply.value, 'hi');

      await Future<void>.delayed(const Duration(milliseconds: 50));

      // Three of the sixteen guarded lines, one per phase of the responder's
      // request handling. Ablate any guard to `if (false)` and the matching row
      // disappears while the call still succeeds — which is exactly the failure
      // this test exists to make loud.
      expect(
        seen.any((m) => m.startsWith('Handling request for /Svc/echo')),
        isTrue,
        reason: 'the guard muted the responder instead of skipping the build',
      );
      expect(seen.any((m) => m.startsWith('Serializing response')), isTrue);
      expect(seen.any((m) => m.startsWith('Sending success trailer')), isTrue);

      await sub.cancel();
      await caller.close();
      await responder.close();
      await clientT.close();
      await serverT.close();
      controller.dispose();
    },
  );
}
