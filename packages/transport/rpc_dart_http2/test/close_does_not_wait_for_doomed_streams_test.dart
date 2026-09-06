// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// close() blocked waiting for streams whose answers it had already thrown away.
//
// It skipped aborting any stream already half-closed locally -- which is every
// ordinary unary call, since they send endStream: true with the request. Those
// streams stayed open on the wire, their subscriptions were then cancelled and
// their controllers closed (so no response could reach the caller), and the
// graceful `finish()` at the end waited for exactly those streams to complete.
//
// Found by running one scenario across the transports and diffing -- 2s handler,
// close() 300ms in:
//
//     websocket : close() 5 ms,    call UNAVAILABLE at 314 ms
//     http2     : close() 1734 ms, call UNAVAILABLE at 2043 ms   <- odd one out
//
// And decisively, with a 600ms handler so the response lands well INSIDE the
// wait: close() took 339ms, the response arrived, and the call STILL failed
// UNAVAILABLE at 648ms. The wait cannot rescue a call; it only delays shutdown.
//
// After: close() 62 ms, call UNAVAILABLE at 372 ms.
@TestOn('vm')
library;

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_http2/rpc_dart_http2.dart';
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

final class _SlowContract extends RpcResponderContract {
  _SlowContract() : super('Svc');

  @override
  void setup() {
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'Slow',
      handler: (request, {RpcContext? context}) async {
        await Future<void>.delayed(const Duration(seconds: 2));
        return 'finished'.rpc;
      },
      requestCodec: _codec,
      responseCodec: _codec,
    );
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'Quick',
      handler: (request, {RpcContext? context}) async => 'quick-ok'.rpc,
      requestCodec: _codec,
      responseCodec: _codec,
    );
  }
}

void main() {
  late RpcHttp2Server server;

  tearDown(() => server.stop().catchError((Object _) {}));

  test(
    'close() returns promptly with a unary call in flight',
    () async {
      server = RpcHttp2Server(
        host: '127.0.0.1',
        port: 0,
        onEndpointCreated: (e) => e.registerServiceContract(_SlowContract()),
      );
      await server.start();

      final transport = await RpcHttp2CallerTransport.connect(
        host: '127.0.0.1',
        port: server.port,
      );
      final caller = RpcCallerEndpoint(transport: transport);

      final call = caller
          .unaryRequest<RpcString, RpcString>(
            serviceName: 'Svc',
            methodName: 'Slow',
            request: 'x'.rpc,
            requestCodec: _codec,
            responseCodec: _codec,
          )
          .then((r) => 'returned ${r.value}')
          .catchError(
            (Object e) => e is RpcStatusException
                ? 'status ${e.statusCode}'
                : e.runtimeType.toString(),
          );

      // Let the call reach the server and half-close locally.
      await Future<void>.delayed(const Duration(milliseconds: 300));

      final sw = Stopwatch()..start();
      await transport.close();
      sw.stop();

      expect(
        sw.elapsed,
        lessThan(const Duration(milliseconds: 900)),
        reason:
            'close() waited for a stream whose response it had already made '
            'undeliverable; the websocket sibling returns in single-digit ms',
      );

      // The call must still end, and end classifiably.
      expect(
        await call.timeout(const Duration(seconds: 10)),
        'status ${RpcStatus.unavailable}',
        reason: 'a closed transport must fail its in-flight calls, not hang',
      );
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  test(
    'GUARD: an ordinary call still completes before close',
    () async {
      // Aborting more streams on close must not disturb calls that finish first.
      server = RpcHttp2Server(
        host: '127.0.0.1',
        port: 0,
        onEndpointCreated: (e) => e.registerServiceContract(_SlowContract()),
      );
      await server.start();

      final transport = await RpcHttp2CallerTransport.connect(
        host: '127.0.0.1',
        port: server.port,
      );
      final caller = RpcCallerEndpoint(transport: transport);

      for (var i = 0; i < 3; i++) {
        final r = await caller
            .unaryRequest<RpcString, RpcString>(
              serviceName: 'Svc',
              methodName: 'Quick',
              request: '$i'.rpc,
              requestCodec: _codec,
              responseCodec: _codec,
            )
            .timeout(const Duration(seconds: 8));
        expect(r.value, 'quick-ok');
      }

      await transport.close();
      expect(transport.isClosed, isTrue);
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  test(
    'GUARD: close() is still prompt with nothing in flight',
    () async {
      server = RpcHttp2Server(
        host: '127.0.0.1',
        port: 0,
        onEndpointCreated: (e) => e.registerServiceContract(_SlowContract()),
      );
      await server.start();

      final transport = await RpcHttp2CallerTransport.connect(
        host: '127.0.0.1',
        port: server.port,
      );

      final sw = Stopwatch()..start();
      await transport.close();
      sw.stop();
      expect(sw.elapsed, lessThan(const Duration(milliseconds: 900)));
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );
}
