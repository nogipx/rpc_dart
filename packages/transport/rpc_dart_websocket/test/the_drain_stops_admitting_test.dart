// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// `stop(drainTimeout:)` stops ACCEPTING new connections and then polls until
// the in-flight count reaches zero. It never told an already-connected peer to
// stop opening streams — WebSocket has no GOAWAY — so it did not drain, it
// waited, serving everything that arrived.
//
// Measured with eight parked server-streams holding the count above zero, so
// both transports spend their whole budget and ADMISSION is the only variable:
//
//                     served after stop began     refused after
//   websocket before          1347                      3
//   websocket after              3                    472
//   http2 (GOAWAY)               4                    540
//
// The damage is not the waiting. Endpoints close when the budget expires, so a
// call admitted at 2.9 s of a 3 s drain is killed at 3.0 — the calls most
// likely to be cut mid-flight are the ones the server accepted after it had
// already decided to shut down. A rolling deploy reaches it every time.

@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_websocket/io.dart';
import 'package:rpc_dart_websocket/rpc_dart_websocket.dart';
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

final class _Svc extends RpcResponderContract {
  _Svc() : super('Svc');

  @override
  void setup() {
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'echo',
      handler: (r, {RpcContext? context}) async => 'ok'.rpc,
      requestCodec: _codec,
      responseCodec: _codec,
    );

    // Answers once and never finishes. THIS is what removes the gap: without a
    // responder that stays live, `drainUntilIdle` samples zero between calls
    // and returns before admission has anything to do — which is how an
    // earlier version of this measurement read pure noise.
    addServerStreamMethod<RpcString, RpcString>(
      methodName: 'park',
      handler: (r, {RpcContext? context}) async* {
        yield 'open'.rpc;
        await Completer<void>().future;
      },
      requestCodec: _codec,
      responseCodec: _codec,
    );
  }
}

void main() {
  test(
    'a drain stops admitting new calls, it does not just wait',
    () async {
      final http = await HttpServer.bind('127.0.0.1', 0);
      final server = RpcWebSocketServer(
        connections: rpcWebSocketConnections(http),
        onEndpointCreated: (e) => e.registerServiceContract(_Svc()),
      );
      await server.start();

      final transport = await RpcWebSocketCallerTransport.connect(
        Uri.parse('ws://127.0.0.1:${http.port}'),
      );
      final caller = RpcCallerEndpoint(transport: transport);

      // Hold the in-flight count above zero for the whole budget.
      final parked = <StreamSubscription<RpcString>>[];
      final answered = <Future<void>>[];
      for (var i = 0; i < 8; i++) {
        final got = Completer<void>();
        parked.add(
          caller
              .serverStream<RpcString, RpcString>(
                serviceName: 'Svc',
                methodName: 'park',
                request: 'x'.rpc,
                requestCodec: _codec,
                responseCodec: _codec,
              )
              .listen(
                (_) {
                  if (!got.isCompleted) got.complete();
                },
                onError: (Object _) {
                  if (!got.isCompleted) got.complete();
                },
              ),
        );
        answered.add(got.future);
      }
      await Future.wait(answered).timeout(const Duration(seconds: 10));

      var served = 0;
      var refused = 0;
      var shuttingDown = false;
      var running = true;

      Future<void> lane() async {
        while (running) {
          try {
            final r = await caller
                .unaryRequest<RpcString, RpcString>(
                  serviceName: 'Svc',
                  methodName: 'echo',
                  request: 'x'.rpc,
                  requestCodec: _codec,
                  responseCodec: _codec,
                )
                .timeout(const Duration(seconds: 2));
            if (shuttingDown && r.value == 'ok') served++;
          } catch (_) {
            if (shuttingDown) {
              refused++;
              await Future<void>.delayed(const Duration(milliseconds: 20));
            }
          }
        }
      }

      unawaited(Future.wait(List.generate(4, (_) => lane())));
      await Future<void>.delayed(const Duration(milliseconds: 400));

      shuttingDown = true;
      await server.stop(drainTimeout: const Duration(seconds: 3));
      running = false;
      await Future<void>.delayed(const Duration(milliseconds: 200));

      // WITNESS. This was 1347 before the drain marked its endpoints.
      expect(
        served,
        lessThan(50),
        reason:
            'the drain admitted $served new calls after shutdown began; it is '
            'supposed to stop admitting, not merely wait',
      );
      // GUARD: the calls have to be REFUSED, not hang. A drain that silently
      // dropped them would also score a low `served`.
      expect(
        refused,
        greaterThan(0),
        reason: 'calls during the drain must be answered UNAVAILABLE, not lost',
      );

      for (final s in parked) {
        unawaited(s.cancel());
      }
      await caller.close().catchError((_) {});
      await transport.close().catchError((_) {});
      await http.close(force: true);
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );
}
