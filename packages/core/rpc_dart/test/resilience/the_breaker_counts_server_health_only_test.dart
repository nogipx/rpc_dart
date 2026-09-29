// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// With `failureOn == null` every error except cancellation counted, so a server
// answering application errors CORRECTLY opened the breaker — and one breaker
// instance covers the whole endpoint, so unrelated methods were refused with it.
//
// Measured at the default threshold of 5, with a second healthy method on the
// same endpoint:
//
//                        before                         after
//   NOT_FOUND            open, healthy method refused   closed, ok
//   INVALID_ARGUMENT     open, healthy method refused   closed, ok
//   PERMISSION_DENIED    open, healthy method refused   closed, ok
//   ALREADY_EXISTS       open, healthy method refused   closed, ok
//   UNIMPLEMENTED        open, healthy method refused   closed, ok
//   UNAVAILABLE          open                           open      <- must stay
//   INTERNAL             open                           open      <- must stay
//   RESOURCE_EXHAUSTED   open                           open      <- must stay
//   cancelled (control)  closed                         closed
//
// The default is deliberately WIDER than `RpcRetryInterceptor`'s transient set: a
// breaker asks "is this endpoint in trouble", a retry asks "is another attempt
// worth making". INTERNAL and UNKNOWN answer the first and not the second.

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

final class _Svc extends RpcResponderContract {
  _Svc(this._status) : super('Svc');

  final int _status;

  @override
  void setup() {
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'lookup',
      requestCodec: _codec,
      responseCodec: _codec,
      handler: (req, {context}) async {
        throw RpcStatusException(_status, 'no such record');
      },
    );
    // A DIFFERENT method, entirely healthy: what an open breaker costs is read
    // here, because the breaker is per interceptor and not per method.
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'healthy',
      requestCodec: _codec,
      responseCodec: _codec,
      handler: (req, {context}) async => 'ok:${req.value}'.rpc,
    );
  }
}

final class _Healthy extends RpcResponderContract {
  _Healthy() : super('Healthy');

  @override
  void setup() {
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'ok',
      requestCodec: _codec,
      responseCodec: _codec,
      handler: (req, {context}) async => 'ok'.rpc,
    );
  }
}

typedef _Outcome = ({CircuitBreakerState state, int failures, String healthy});

Future<_Outcome> _fiveFailuresThenHealthy(int status) async {
  final (client, server) = RpcChannelTransport.pair();
  final responder = RpcResponderEndpoint(transport: server)
    ..registerServiceContract(_Svc(status)..setup())
    ..start();
  final caller = RpcCallerEndpoint(transport: client);
  final breaker = RpcCircuitBreakerInterceptor(failureThreshold: 5);
  caller.addInterceptor(breaker);
  addTearDown(() async {
    await caller.close();
    await responder.close();
  });

  Future<String> call(String method) async {
    try {
      final r = await caller.unaryRequest<RpcString, RpcString>(
        serviceName: 'Svc',
        methodName: method,
        request: 'x'.rpc,
        requestCodec: _codec,
        responseCodec: _codec,
      );
      return r.value;
    } catch (e) {
      return e is CircuitBreakerOpenException ? 'BREAKER OPEN' : '$e';
    }
  }

  for (var i = 0; i < 5; i++) {
    await call('lookup');
  }
  return (
    state: breaker.state,
    failures: breaker.failureCount,
    healthy: await call('healthy'),
  );
}

void main() {
  group('WITNESS: an application error is not a health signal', () {
    for (final (name, status) in [
      ('NOT_FOUND', RpcStatus.notFound),
      ('INVALID_ARGUMENT', RpcStatus.invalidArgument),
      ('PERMISSION_DENIED', RpcStatus.permissionDenied),
      ('ALREADY_EXISTS', RpcStatus.alreadyExists),
      // A caller with a typo in the method name is the sharpest case: under the
      // old default it took the whole endpoint down for every OTHER method.
      ('UNIMPLEMENTED', RpcStatus.unimplemented),
    ]) {
      test(
        '$name does not open the breaker',
        () async {
          final out = await _fiveFailuresThenHealthy(status);

          expect(
            out.state,
            CircuitBreakerState.closed,
            reason:
                'five $name answers are a working server, and opening on them '
                'blocks every other method on the endpoint',
          );
          expect(out.failures, 0);
          expect(
            out.healthy,
            'ok:x',
            reason: 'an unrelated healthy method was refused',
          );
        },
        timeout: const Timeout(Duration(seconds: 30)),
      );
    }
  });

  group('GUARD: a server in trouble still opens it', () {
    for (final (name, status) in [
      ('UNAVAILABLE', RpcStatus.unavailable),
      ('INTERNAL', RpcStatus.internal),
      ('RESOURCE_EXHAUSTED', RpcStatus.resourceExhausted),
      ('UNKNOWN', RpcStatus.unknown),
      ('DEADLINE_EXCEEDED', RpcStatus.deadlineExceeded),
    ]) {
      test('$name opens the breaker', () async {
        final out = await _fiveFailuresThenHealthy(status);

        expect(
          out.state,
          CircuitBreakerState.open,
          reason:
              'narrowing the default must not disarm the breaker for what it '
              'exists to catch',
        );
        expect(out.failures, greaterThanOrEqualTo(5));
      }, timeout: const Timeout(Duration(seconds: 30)));
    }
  });

  test(
    'GUARD: an error with no status still counts',
    () async {
      // An error carrying no status is not an application answering; it is
      // something failing, and the default must not read "unclassifiable" as
      // benign. A codec that throws on decode is the cheapest such error: it
      // arrives as a bare StateError, measured in
      // `.dart_tool/probe/b110_what_error.dart`.
      final (client, server) = RpcChannelTransport.pair();
      final responder = RpcResponderEndpoint(transport: server)
        ..registerServiceContract(_Healthy()..setup())
        ..start();
      final caller = RpcCallerEndpoint(transport: client);
      final breaker = RpcCircuitBreakerInterceptor(failureThreshold: 2);
      caller.addInterceptor(breaker);
      addTearDown(() async {
        await caller.close();
        await responder.close();
      });

      for (var i = 0; i < 2; i++) {
        try {
          await caller.unaryRequest<RpcString, RpcString>(
            serviceName: 'Healthy',
            methodName: 'ok',
            request: 'x'.rpc,
            requestCodec: _codec,
            responseCodec: RpcCodec<RpcString>((_) => throw StateError('boom')),
          );
        } catch (_) {}
      }

      expect(
        breaker.failureCount,
        greaterThanOrEqualTo(2),
        reason: 'an error with no status is not a server answering correctly',
      );
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );

  test(
    'GUARD: an explicit failureOn still replaces the default',
    () async {
      final (client, server) = RpcChannelTransport.pair();
      final responder = RpcResponderEndpoint(transport: server)
        ..registerServiceContract(_Svc(RpcStatus.notFound)..setup())
        ..start();
      final caller = RpcCallerEndpoint(transport: client);
      // Counts EVERYTHING, which is what the old default did — a caller who wants
      // that must still be able to ask for it.
      final breaker = RpcCircuitBreakerInterceptor(
        failureThreshold: 5,
        failureOn: (_) => true,
      );
      caller.addInterceptor(breaker);
      addTearDown(() async {
        await caller.close();
        await responder.close();
      });

      for (var i = 0; i < 5; i++) {
        try {
          await caller.unaryRequest<RpcString, RpcString>(
            serviceName: 'Svc',
            methodName: 'lookup',
            request: 'x'.rpc,
            requestCodec: _codec,
            responseCodec: _codec,
          );
        } catch (_) {}
      }

      expect(breaker.state, CircuitBreakerState.open);
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );
}
