// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// stop() closed every endpoint at once, so a rolling deploy dropped every call
// that happened to be running. It dropped them CORRECTLY -- measured with a 2s
// handler and stop() 300ms in, the caller got a prompt, retryable UNAVAILABLE
// at 326ms -- so this was a missing capability, not a broken one.
//
//     stop()                 : in-flight call -> UNAVAILABLE(14) after 326ms
//     stop(drainTimeout: 5s) : in-flight call -> returned its real answer at
//                              2014ms, and stop() itself waited 1711ms
//
// The budget is mandatory rather than optional: accepting has stopped by then,
// but an EXISTING connection can still open new streams and this transport has
// no GOAWAY equivalent to forbid it, so a peer that keeps calling would hold
// shutdown open forever.
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
  }
}

void main() {
  late RpcHttp2Server server;

  tearDown(() => server.stop().catchError((Object _) {}));

  /// Starts a server, fires a slow call, and returns a future for its outcome.
  Future<Future<String>> startSlowCall() async {
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
    addTearDown(() => transport.close().catchError((Object _) {}));
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

    // Let the call reach the handler before anything is stopped.
    await Future<void>.delayed(const Duration(milliseconds: 300));
    return call;
  }

  test(
    'a drained stop lets an in-flight call finish',
    () async {
      final call = await startSlowCall();

      await server.stop(drainTimeout: const Duration(seconds: 10));

      expect(
        await call.timeout(const Duration(seconds: 20)),
        'returned finished',
        reason:
            'the whole point of a drain is that the call completes instead of '
            'being cut off',
      );
    },
    timeout: const Timeout(Duration(seconds: 90)),
  );

  test(
    'CONTROL: without a drain the in-flight call is cut off, but correctly',
    () async {
      // Proves the slow call really is in flight when stop() lands -- otherwise
      // the witness above could pass for the wrong reason -- and pins the
      // forceful behaviour as still correct and still the default.
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
    timeout: const Timeout(Duration(seconds: 90)),
  );

  test(
    'GUARD: the drain budget is honoured when a call never finishes',
    () async {
      // A handler that outlives the budget must not hold shutdown open forever.
      server = RpcHttp2Server(
        host: '127.0.0.1',
        port: 0,
        onEndpointCreated: (e) => e.registerServiceContract(_ForeverContract()),
      );
      await server.start();

      final transport = await RpcHttp2CallerTransport.connect(
        host: '127.0.0.1',
        port: server.port,
      );
      addTearDown(() => transport.close().catchError((Object _) {}));
      final caller = RpcCallerEndpoint(transport: transport);
      unawaited(
        caller
            .unaryRequest<RpcString, RpcString>(
              serviceName: 'Svc',
              methodName: 'Forever',
              request: 'x'.rpc,
              requestCodec: _codec,
              responseCodec: _codec,
            )
            .catchError((Object _) => 'x'.rpc),
      );
      await Future<void>.delayed(const Duration(milliseconds: 300));

      final sw = Stopwatch()..start();
      await server.stop(drainTimeout: const Duration(milliseconds: 600));
      sw.stop();

      expect(
        sw.elapsed,
        lessThan(const Duration(seconds: 5)),
        reason: 'the budget must bound shutdown even if the call never ends',
      );
    },
    timeout: const Timeout(Duration(seconds: 90)),
  );

  test(
    'GUARD: a drained stop with nothing in flight returns promptly',
    () async {
      server = RpcHttp2Server(
        host: '127.0.0.1',
        port: 0,
        onEndpointCreated: (e) => e.registerServiceContract(_SlowContract()),
      );
      await server.start();

      final sw = Stopwatch()..start();
      await server.stop(drainTimeout: const Duration(seconds: 10));
      sw.stop();

      expect(
        sw.elapsed,
        lessThan(const Duration(seconds: 2)),
        reason: 'an idle server must not wait out the budget',
      );
    },
    timeout: const Timeout(Duration(seconds: 90)),
  );
}

final class _ForeverContract extends RpcResponderContract {
  _ForeverContract() : super('Svc');

  @override
  void setup() {
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'Forever',
      handler: (request, {RpcContext? context}) async {
        await Future<void>.delayed(const Duration(seconds: 30));
        return 'never'.rpc;
      },
      requestCodec: _codec,
      responseCodec: _codec,
    );
  }
}
