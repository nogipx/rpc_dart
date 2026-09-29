// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// The middleware loops await inside the loop body, so the list can be mutated
// between two `moveNext()` calls — and both mutators are ordinary API: `close()`
// clears the list, `addMiddleware` appends to it. Iterating the list itself threw
// ConcurrentModificationError into the in-flight call, which is a StateError, so
// the caller got that instead of an RPC status.
//
// Each arm parks a call inside the middleware loop and disturbs the list while it
// is parked, then reads the error TYPE the caller ends up with — which is the whole
// finding. The close() arm still FAILS, and must: the endpoint is closing. What
// matters is that it now fails with its own status rather than with a StateError,
// so a test asking only "did the call succeed" would score the fix as no change.
//
// The arm with NO middleware is what localises this: an empty loop never awaits, so
// it never observes the mutation, and without it "close() breaks an in-flight call"
// explains the results just as well.
//
// The measurements are in `.claude/loop/rounds/505`.

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

final class _SlowMiddleware extends IRpcMiddleware {
  _SlowMiddleware(this.parked);

  final Duration parked;

  @override
  FutureOr<TRequest> processRequest<TRequest>(
    RpcMiddlewareContext context,
    TRequest request,
  ) async {
    await Future<void>.delayed(parked);
    return request;
  }

  @override
  FutureOr<TResponse> processResponse<TResponse>(
    RpcMiddlewareContext context,
    TResponse response,
  ) => response;
}

final class _Svc extends RpcResponderContract {
  _Svc() : super('Svc');

  @override
  void setup() {
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'echo',
      requestCodec: _codec,
      responseCodec: _codec,
      handler: (req, {context}) async => 'echo:${req.value}'.rpc,
    );
  }
}

/// Starts a call that parks inside the middleware loop, runs [disturb] while it is
/// parked, and returns what the call ended up with.
Future<String> _armed(
  Future<void> Function(RpcCallerEndpoint caller)? disturb, {
  int middlewares = 1,
}) async {
  final (client, server) = RpcChannelTransport.pair();
  final responder = RpcResponderEndpoint(transport: server)
    ..registerServiceContract(_Svc())
    ..start();
  final caller = RpcCallerEndpoint(transport: client);
  for (var i = 0; i < middlewares; i++) {
    caller.addMiddleware(_SlowMiddleware(const Duration(milliseconds: 200)));
  }
  addTearDown(() async {
    try {
      await caller.close();
    } catch (_) {}
    await responder.close();
  });

  final call = caller
      .unaryRequest<RpcString, RpcString>(
        serviceName: 'Svc',
        methodName: 'echo',
        request: 'x'.rpc,
        requestCodec: _codec,
        responseCodec: _codec,
        context: RpcContext.empty().withTimeout(const Duration(seconds: 5)),
      )
      .then((r) => 'OK ${r.value}')
      .catchError((Object e) => '${e.runtimeType}');

  await Future<void>.delayed(const Duration(milliseconds: 100));
  if (disturb != null) await disturb(caller);
  return call;
}

void main() {
  group('WITNESS: mutating the middleware list mid-call is not a StateError', () {
    test(
      'close() while a call is parked in a middleware',
      () async {
        final outcome = await _armed((c) => c.close());

        expect(
          outcome,
          isNot('ConcurrentModificationError'),
          reason:
              'close() clears the list the loop is iterating, so the call failed '
              'with a StateError instead of its own status',
        );
        expect(
          outcome,
          'RpcCancelledException',
          reason: 'a call interrupted by close() should read as cancelled',
        );
      },
      timeout: const Timeout(Duration(seconds: 30)),
    );

    test(
      'addMiddleware while a call is parked in a middleware',
      () async {
        final outcome = await _armed((c) async {
          c.addMiddleware(_SlowMiddleware(Duration.zero));
        });

        expect(
          outcome,
          'OK echo:x',
          reason:
              'a middleware added after the call started simply does not apply to '
              'it; appending to the list must not fail the call',
        );
      },
      timeout: const Timeout(Duration(seconds: 30)),
    );
  });

  group('GUARD', () {
    test(
      'an undisturbed call still goes through the middleware',
      () async {
        // Without this, every row above is equally consistent with a middleware
        // that is never invoked at all.
        expect(await _armed(null), 'OK echo:x');
      },
      timeout: const Timeout(Duration(seconds: 30)),
    );

    test(
      'close() during a call with NO middleware was always fine',
      () async {
        // With an empty list the loop never awaits, so moveNext() is never called a
        // second time and the mutation cannot be seen. This arm pins the defect to
        // the iteration rather than to close().
        expect(await _armed((c) => c.close(), middlewares: 0), 'OK echo:x');
      },
      timeout: const Timeout(Duration(seconds: 30)),
    );

    test(
      'two middlewares both run, in order, on request and response',
      () async {
        // The fix copies the list, and a copy is one edit away from a copy that is
        // built wrong (empty, or reversed on the request half). This reads the
        // ORDER, which nothing else here does.
        final trace = <String>[];
        final (client, server) = RpcChannelTransport.pair();
        final responder = RpcResponderEndpoint(transport: server)
          ..registerServiceContract(_Svc())
          ..start();
        final caller = RpcCallerEndpoint(transport: client)
          ..addMiddleware(_TracingMiddleware('a', trace))
          ..addMiddleware(_TracingMiddleware('b', trace));
        addTearDown(() async {
          await caller.close();
          await responder.close();
        });

        final r = await caller.unaryRequest<RpcString, RpcString>(
          serviceName: 'Svc',
          methodName: 'echo',
          request: 'x'.rpc,
          requestCodec: _codec,
          responseCodec: _codec,
        );

        expect(r.value, 'echo:x');
        expect(trace, [
          'req:a',
          'req:b',
          'res:b',
          'res:a',
        ], reason: 'requests run forwards, responses backwards');
      },
      timeout: const Timeout(Duration(seconds: 30)),
    );
  });
}

final class _TracingMiddleware extends IRpcMiddleware {
  _TracingMiddleware(this.name, this.trace);

  final String name;
  final List<String> trace;

  @override
  FutureOr<TRequest> processRequest<TRequest>(
    RpcMiddlewareContext context,
    TRequest request,
  ) async {
    trace.add('req:$name');
    return request;
  }

  @override
  FutureOr<TResponse> processResponse<TResponse>(
    RpcMiddlewareContext context,
    TResponse response,
  ) async {
    trace.add('res:$name');
    return response;
  }
}
