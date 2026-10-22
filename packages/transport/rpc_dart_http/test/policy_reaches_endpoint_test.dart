// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// The responder pipeline reads maxConcurrentHandlers, halfOpenStreamTimeout and
// the pre-method buffer budget from the transport's `securityPolicy`.
//
// RpcHttpResponderTransport also enforces maxActiveStreams, the method path,
// metadata and the body size itself; the policy it was given must reach the
// pipeline too, or everything the pipeline owns is inert. This drives
// maxConcurrentHandlers: 3 (with maxActiveStreams: 1000, so nothing is refused
// for lack of a stream slot) against 30 concurrent calls into a handler that
// parks: at most 3 enter, the rest are refused RESOURCE_EXHAUSTED.

@TestOn('vm')
library;

import 'dart:async';

import 'package:rpc_dart/transport.dart';
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

Future<_Rig> _serve({
  RpcSecurityPolicy policy = const RpcSecurityPolicy(),
}) async {
  final gate = Completer<void>();
  final transport = RpcHttpResponderTransport(policy: policy);
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
    .unary<RpcString, RpcString>(
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

    final IRpcTransport asTransport = rig.transport;
    expect(asTransport.securityPolicy.maxConcurrentHandlers, 7);
  });

  test('GUARD: no policy still serves, with the defaults', () async {
    // A server that passes nothing gets `const RpcSecurityPolicy()`.
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
