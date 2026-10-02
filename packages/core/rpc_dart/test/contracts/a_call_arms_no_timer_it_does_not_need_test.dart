// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// RpcCallScope bounded EVERY disposer with `.timeout()`, synchronous ones too,
// so a server-stream call with no deadline armed nine timers, eight of them for
// disposers that cannot hang. Counted in a Zone, which sees every Timer.
//
// Endpoints are built INSIDE the zone: a subscription creates its timers in the
// zone it was registered in, and building them outside hides the responder half.

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

final class _Svc extends RpcResponderContract {
  _Svc() : super('Svc');

  @override
  void setup() {
    addServerStreamMethod<RpcString, RpcString>(
      methodName: 'tick',
      requestCodec: _codec,
      responseCodec: _codec,
      handler: (req, {context}) async* {
        yield req;
      },
    );
  }
}

void main() {
  test('a server-stream call with no deadline arms only its half-open '
      'timer', () async {
    var timers = 0;
    const calls = 20;
    await runZoned(
      () async {
        final (client, server) = RpcChannelTransport.pair();
        final responder = RpcResponderEndpoint(transport: server)
          ..registerServiceContract(_Svc())
          ..start();
        final caller = RpcCallerEndpoint(transport: client);
        Future<void> once() => caller
            .serverStream<RpcString, RpcString>(
              serviceName: 'Svc',
              methodName: 'tick',
              request: 'x'.rpc,
              requestCodec: _codec,
              responseCodec: _codec,
            )
            .drain<void>();

        // The first call arms what belongs to the connection.
        await once();
        await Future<void>.delayed(const Duration(milliseconds: 50));
        timers = 0;
        for (var i = 0; i < calls; i++) {
          await once();
        }
        await Future<void>.delayed(const Duration(milliseconds: 50));
        final perCall = timers / calls;
        await caller.close();
        await responder.close();
        expect(
          perCall,
          lessThan(2),
          reason: '$perCall timers per call; one is the half-open guard',
        );
      },
      zoneSpecification: ZoneSpecification(
        createTimer: (self, parent, zone, duration, f) {
          timers++;
          return parent.createTimer(zone, duration, f);
        },
      ),
    );
  });

  test('GUARD: an async disposer that hangs is still abandoned', () async {
    final previous = RpcCallScope.disposerTimeout;
    RpcCallScope.disposerTimeout = const Duration(milliseconds: 50);
    addTearDown(() => RpcCallScope.disposerTimeout = previous);

    final scope = RpcCallScope();
    scope.onDispose(() => Completer<void>().future);
    await scope.close().timeout(
      const Duration(seconds: 2),
      onTimeout: () => fail('a hanging async disposer blocked close()'),
    );
  });
}
