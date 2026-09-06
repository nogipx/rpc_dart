// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// The HTTP/1.1 half of the graceful-drain capability; http2 and websocket
// gained it first. stop() force-closed, so a rolling deploy dropped every
// request that happened to be running. It dropped them correctly -- the caller
// gets UNAVAILABLE at 325ms -- so this was a missing capability, not a broken
// one.
//
//     stop()                 : in-flight request -> UNAVAILABLE(14) at 325 ms
//     stop(drainTimeout: 5s) : in-flight request -> returned its real answer at
//                              2087 ms, and stop() itself waited 1777 ms
//
// `HttpServer.close(force: false)` is NOT a drain, which is worth pinning
// because it reads like one: it stops listening and completes as soon as the
// port is released -- measured at 4ms with a 2s request still running. A first
// attempt relied on it, closed the endpoint immediately afterwards, and the
// caller HUNG for the full 20s budget with the connection open and no answer
// coming. The wait has to be explicit.
@TestOn('vm')
library;

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_http/rpc_dart_http.dart';
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
  }
}

void main() {
  late RpcHttpServer server;

  tearDown(() => server.stop().catchError((Object _) {}));

  /// Starts a server and fires a slow call, returning a future of its outcome.
  Future<Future<String>> startSlowCall() async {
    server = RpcHttpServer(
      host: '127.0.0.1',
      port: 0,
      onEndpointCreated: (e) {
        e.registerServiceContract(_SlowContract());
        e.start();
      },
    );
    await server.start();
    await server.afterModulesStart();

    final transport = RpcHttpCallerTransport(
      baseUrl: 'http://127.0.0.1:${server.actualPort}',
    );
    addTearDown(() => transport.close());
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

    await Future<void>.delayed(const Duration(milliseconds: 300));
    return call;
  }

  test(
    'a drained stop lets an in-flight request finish',
    () async {
      final call = await startSlowCall();

      await server.stop(drainTimeout: const Duration(seconds: 10));

      expect(
        await call.timeout(const Duration(seconds: 20)),
        'returned finished',
        reason:
            'the whole point of a drain is that the request completes instead of '
            'being cut off -- and that it is ANSWERED, not merely left running',
      );
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  test(
    'CONTROL: without a drain the request is cut off, but correctly',
    () async {
      // Proves the slow request really is in flight when stop() lands, and pins
      // the forceful behaviour as still correct and still the default.
      final call = await startSlowCall();

      await server.stop();

      expect(
        await call.timeout(const Duration(seconds: 20)),
        'status ${RpcStatus.unavailable}',
        reason:
            'a forceful stop must still fail the call with a prompt, '
            'classifiable, retryable status',
      );
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  test(
    'GUARD: a drained stop with nothing in flight returns promptly',
    () async {
      server = RpcHttpServer(
        host: '127.0.0.1',
        port: 0,
        onEndpointCreated: (e) {
          e.registerServiceContract(_SlowContract());
          e.start();
        },
      );
      await server.start();
      await server.afterModulesStart();

      final sw = Stopwatch()..start();
      await server.stop(drainTimeout: const Duration(seconds: 10));
      sw.stop();

      expect(
        sw.elapsed,
        lessThan(const Duration(seconds: 2)),
        reason: 'an idle server must not wait out the budget',
      );
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );
}
