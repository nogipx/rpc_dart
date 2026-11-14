// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';
import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

const _codec = RpcCodec<RpcString>(RpcString.fromJson);

final class _Echo extends RpcResponderContract {
  _Echo() : super('Test');

  @override
  void setup() {
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'Echo',
      handler: (request, {RpcContext? context}) async => request,
      requestCodec: _codec,
      responseCodec: _codec,
    );
  }
}

void main() {
  for (final timed in [false, true]) {
    test(
      'a ${timed ? 'timed' : 'deadline-free'} call shares deadline ownership',
      () async {
        var deadlineTimers = 0;
        await runZoned<Future<void>>(
          () async {
            final (client, server) = RpcChannelTransport.memoryPair();
            final caller = RpcCallerEndpoint(transport: client);
            final responder = RpcResponderEndpoint(transport: server)
              ..registerServiceContract(_Echo())
              ..start();
            try {
              final answer = await caller.unary<RpcString, RpcString>(
                serviceName: 'Test',
                methodName: 'Echo',
                request: 'hello'.rpc,
                requestCodec: _codec,
                responseCodec: _codec,
                context: timed
                    ? RpcContext.empty().withTimeout(const Duration(minutes: 5))
                    : null,
              );
              expect(answer.value, 'hello');
              expect(
                deadlineTimers,
                timed ? 2 : 0,
                reason: 'each endpoint owns one deadline timer',
              );
            } finally {
              await caller.close();
              await responder.close();
            }
          },
          zoneSpecification: ZoneSpecification(
            createTimer: (self, parent, zone, duration, callback) {
              if (duration >= const Duration(minutes: 4) &&
                  duration <= const Duration(minutes: 5)) {
                deadlineTimers++;
              }
              return parent.createTimer(zone, duration, callback);
            },
          ),
        );
      },
    );
  }
}
