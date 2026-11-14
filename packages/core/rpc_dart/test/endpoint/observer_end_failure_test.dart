// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';
import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

final class _Observer extends RpcCallObserverInterceptor<void> {
  final outcomes = <RpcCallOutcome>[];
  final failure = StateError('observer failed');

  @override
  void onCallStart(RpcCallInfo call, RpcMethodType type) {}

  @override
  void onCallEnd(void state, RpcCallOutcome outcome, Duration duration) {
    outcomes.add(outcome);
    throw failure;
  }
}

void main() {
  for (final streaming in [false, true]) {
    test(
      'an end hook is called once for ${streaming ? 'client stream' : 'unary'}',
      () async {
        final (client, server) = RpcChannelTransport.memoryPair();
        final endpoint = RpcCallerEndpoint(transport: client);
        addTearDown(endpoint.close);
        addTearDown(server.close);
        final observer = _Observer();
        final call = RpcCallInfo(
          endpoint: endpoint,
          serviceName: 'Test',
          methodName: 'Echo',
          context: RpcContext.empty(),
          direction: RpcCallDirection.outgoing,
        );
        var handlerCalls = 0;
        final result = streaming
            ? observer.interceptClientStream<int, int>(call, Stream.value(1), (
                _,
                values,
              ) async {
                handlerCalls++;
                return values.first;
              })
            : observer.interceptUnary<int, int>(call, 1, (_, value) async {
                handlerCalls++;
                return value;
              });
        await expectLater(result, throwsA(same(observer.failure)));
        expect(handlerCalls, 1);
        expect(observer.outcomes, [isA<RpcCallSucceeded>()]);
      },
    );
  }
}
