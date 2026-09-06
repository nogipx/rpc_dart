// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// The responder pipeline reads maxActiveStreams and halfOpenStreamTimeout, and
// the stream parsers read maxMessageLengthBytes, through an
// `is IRpcSecurityPolicyAware` check on the transport -- falling back to
// `const RpcSecurityPolicy()` when it is absent.
//
// RpcHttp2Server plumbs its securityPolicy into RpcHttp2ResponderTransport, but
// that transport declared only IRpcTransport, so the pipeline never saw it.
// Nothing else bounds inbound concurrency here: the server does not derive
// SETTINGS_MAX_CONCURRENT_STREAMS from the policy, so the pipeline is the only
// enforcer.
//
// Measured against a server configured `maxActiveStreams: 3`, with a permissive
// client so the client's own limiter is not what is being tested:
//
//   before: 60 of 60 concurrent streams admitted
//   after :  3 of 60

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_http2/rpc_dart_http2.dart';
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);
Completer<void> _gate = Completer<void>();

final class _Contract extends RpcResponderContract {
  _Contract() : super('Svc');

  @override
  void setup() {
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'park',
      handler: (request, {RpcContext? context}) async {
        await _gate.future;
        return 'done'.rpc;
      },
      requestCodec: _codec,
      responseCodec: _codec,
    );
  }
}

void main() {
  setUp(() => _gate = Completer<void>());
  tearDown(() {
    if (!_gate.isCompleted) _gate.complete();
  });

  test('an http2 server honours the maxActiveStreams it was given', () async {
    RpcResponderEndpoint? serverEndpoint;

    final server = RpcHttp2Server(
      host: '127.0.0.1',
      port: 0,
      securityPolicy: const RpcSecurityPolicy(maxActiveStreams: 3),
      onEndpointCreated: (endpoint) {
        serverEndpoint = endpoint;
        endpoint.registerServiceContract(_Contract());
      },
    );
    await server.start();

    final client = await RpcHttp2CallerTransport.connect(
      host: '127.0.0.1',
      port: server.port,
      // Permissive, so the ceiling under test is the server's.
      policy: const RpcSecurityPolicy(maxActiveStreams: 100000),
    );
    final caller = RpcCallerEndpoint(transport: client);

    addTearDown(() async {
      if (!_gate.isCompleted) _gate.complete();
      await caller.close();
      await client.close();
      await server.stop();
    });

    final calls = <Future<Object>>[
      for (var i = 0; i < 60; i++)
        caller
            .unaryRequest<RpcString, RpcString>(
              serviceName: 'Svc',
              methodName: 'park',
              request: 'x'.rpc,
              requestCodec: _codec,
              responseCodec: _codec,
            )
            .then<Object>((r) => r, onError: (Object e) => e),
    ];

    await Future<void>.delayed(const Duration(seconds: 2));

    expect(
      serverEndpoint?.collectEndpointMetrics()['openStreams'],
      lessThanOrEqualTo(3),
      reason:
          'the pipeline could not see the policy, so it fell back to the '
          'default ceiling and admitted every stream the peer opened',
    );

    expect(serverEndpoint?.transport, isA<IRpcSecurityPolicyAware>());
    expect(client, isA<IRpcSecurityPolicyAware>());
    expect(
      (client as IRpcSecurityPolicyAware).securityPolicy.maxActiveStreams,
      100000,
      reason: 'the caller must report its own policy, not a default one',
    );

    // The refused calls must be told why rather than left hanging.
    _gate.complete();
    final results = await Future.wait(calls);
    expect(
      results.whereType<RpcStatusException>().where(
        (e) => e.statusCode == RpcStatus.resourceExhausted,
      ),
      isNotEmpty,
    );
  });

  test('an http2 server honours maxConcurrentHandlers too', () async {
    // Same plumbing, different field -- and worth its own case because this one
    // bounds WORK rather than stream state: a handler that outlives its call
    // keeps its slot, which is invisible to `openStreams`. If the transport
    // ever stops declaring IRpcSecurityPolicyAware the ceiling silently
    // disappears, exactly as maxActiveStreams once did.
    RpcResponderEndpoint? serverEndpoint;

    final server = RpcHttp2Server(
      host: '127.0.0.1',
      port: 0,
      securityPolicy: const RpcSecurityPolicy(
        maxActiveStreams: 1000,
        maxConcurrentHandlers: 3,
      ),
      onEndpointCreated: (endpoint) {
        serverEndpoint = endpoint;
        endpoint.registerServiceContract(_Contract());
      },
    );
    await server.start();

    final client = await RpcHttp2CallerTransport.connect(
      host: '127.0.0.1',
      port: server.port,
      policy: const RpcSecurityPolicy(maxActiveStreams: 100000),
    );
    final caller = RpcCallerEndpoint(transport: client);

    addTearDown(() async {
      if (!_gate.isCompleted) _gate.complete();
      await caller.close();
      await client.close();
      await server.stop();
    });

    final calls = <Future<Object>>[
      for (var i = 0; i < 30; i++)
        caller
            .unaryRequest<RpcString, RpcString>(
              serviceName: 'Svc',
              methodName: 'park',
              request: 'x'.rpc,
              requestCodec: _codec,
              responseCodec: _codec,
            )
            .then<Object>((r) => r, onError: (Object e) => e),
    ];

    await Future<void>.delayed(const Duration(seconds: 2));

    // Stream state is NOT the limit here: 1000 streams are allowed, so anything
    // refused was refused by the handler ceiling.
    expect(
      serverEndpoint?.collectEndpointMetrics()['openStreams'],
      lessThanOrEqualTo(3),
    );

    _gate.complete();
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
}
