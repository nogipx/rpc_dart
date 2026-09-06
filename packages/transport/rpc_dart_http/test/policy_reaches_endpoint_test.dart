// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// The responder pipeline reads maxConcurrentHandlers, halfOpenStreamTimeout and
// the pre-method buffer budget through an `is IRpcSecurityPolicyAware` check on
// the transport, falling back to `const RpcSecurityPolicy()` when it is absent.
//
// RpcHttpResponderTransport took a securityPolicy, enforced maxActiveStreams,
// the method path, metadata and the body size ITSELF -- and declared only
// IRpcTransport, so everything the pipeline owns was silently inert. Measured
// with maxConcurrentHandlers: 3 (and maxActiveStreams: 1000, so nothing is
// refused for lack of a stream slot) against 30 concurrent calls into a handler
// that parks:
//
//   transport is IRpcSecurityPolicyAware : false
//   handlers entered                     : 30 of 30
//
//   after: 3, with 27 refused RESOURCE_EXHAUSTED
//
// The sibling asymmetry was inside this package: RpcHttpCallerTransport has
// reported its policy this way all along, and RpcHttp2ResponderTransport had
// this exact defect fixed in round 76. isolate and wasm are unaffected -- both
// return a real RpcChannelTransport, which implements the capability.

@TestOn('vm')
library;

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_http/rpc_dart_http.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

class _Svc extends RpcResponderContract {
  _Svc(this.gate) : super('Svc');

  final Completer<void> gate;
  int entered = 0;

  @override
  void setup() {
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'park',
      handler: (request, {RpcContext? context}) async {
        entered++;
        await gate.future;
        return 'done'.rpc;
      },
      requestCodec: _codec,
      responseCodec: _codec,
    );
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'quick',
      handler: (request, {RpcContext? context}) async => 'ok'.rpc,
      requestCodec: _codec,
      responseCodec: _codec,
    );
  }
}

typedef _Rig = ({
  RpcHttpResponderTransport transport,
  RpcCallerEndpoint caller,
  _Svc svc,
});

Future<_Rig> _serve({RpcSecurityPolicy? policy}) async {
  final gate = Completer<void>();
  final transport = RpcHttpResponderTransport(securityPolicy: policy);
  final responder = RpcResponderEndpoint(transport: transport);
  final svc = _Svc(gate);
  responder.registerServiceContract(svc);
  responder.start();

  final server = await shelf_io.serve(transport.handler, '127.0.0.1', 0);
  final client = RpcHttpCallerTransport(
    baseUrl: 'http://127.0.0.1:${server.port}',
  );
  final caller = RpcCallerEndpoint(transport: client);

  addTearDown(() async {
    if (!gate.isCompleted) gate.complete();
    await caller.close();
    await client.close();
    await responder.close();
    await server.close(force: true);
  });

  return (transport: transport, caller: caller, svc: svc);
}

Future<Object> _call(_Rig rig, String method) => rig.caller
    .unaryRequest<RpcString, RpcString>(
      serviceName: 'Svc',
      methodName: method,
      request: 'x'.rpc,
      requestCodec: _codec,
      responseCodec: _codec,
    )
    .then<Object>((r) => r, onError: (Object e) => e);

void main() {
  test('an HTTP/1.1 server honours maxConcurrentHandlers', () async {
    // maxActiveStreams is deliberately generous: the transport enforces THAT
    // one itself, so with both at 3 either would cap the other's breach and the
    // case would prove nothing about the pipeline seeing the policy.
    final rig = await _serve(
      policy: const RpcSecurityPolicy(
        maxActiveStreams: 1000,
        maxConcurrentHandlers: 3,
      ),
    );

    final calls = [for (var i = 0; i < 30; i++) _call(rig, 'park')];
    await Future<void>.delayed(const Duration(seconds: 2));

    expect(rig.svc.entered, lessThanOrEqualTo(3));

    if (!rig.svc.gate.isCompleted) rig.svc.gate.complete();
    final results = await Future.wait(calls);
    expect(
      results.whereType<RpcStatusException>().where(
        (e) =>
            e.statusCode == RpcStatus.resourceExhausted &&
            e.message.contains('concurrent handlers'),
      ),
      isNotEmpty,
      reason: 'the handler ceiling never reached the pipeline',
    );
  });

  test('the transport reports the policy it was given', () async {
    const policy = RpcSecurityPolicy(maxConcurrentHandlers: 7);
    final rig = await _serve(policy: policy);

    expect(rig.transport, isA<IRpcSecurityPolicyAware>());
    expect(
      (rig.transport as IRpcSecurityPolicyAware)
          .securityPolicy
          .maxConcurrentHandlers,
      7,
    );
  });

  test('GUARD: no policy still serves, with the defaults', () async {
    // The getter falls back to `const RpcSecurityPolicy()`, which is exactly
    // what the pipeline used when the capability was absent -- so a server that
    // passes nothing must see no change at all.
    final rig = await _serve();

    expect(rig.transport.securityPolicy.maxConcurrentHandlers, isNull);
    expect(rig.transport.securityPolicy.maxActiveStreams, 4096);
    expect(await _call(rig, 'quick'), isA<RpcString>());
  });

  test('GUARD: an ordinary call is unaffected by a generous ceiling', () async {
    final rig = await _serve(
      policy: const RpcSecurityPolicy(maxConcurrentHandlers: 100),
    );
    expect(await _call(rig, 'quick'), isA<RpcString>());
  });
}
