// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// RpcHttpServer.afterModulesStart() created the RpcResponderEndpoint and called
// onEndpointCreated, but never called endpoint.start().
//
// Both sibling servers do it themselves -- RpcHttp2Server._handleConnection and
// RpcWebSocketServer._handleConnection each call endpoint.start() right after
// their own onEndpointCreated -- so an application written by analogy
// registered its contracts and got a server that accepted connections and
// answered nothing:
//
//   app calls endpoint.start()        : echo-ok
//   app does NOT call endpoint.start(): HUNG, the server answered nothing
//
// A silent hang on both sides, for a callback the other two servers do not
// require. The existing suite missed it because the one test that makes a real
// round trip through RpcHttpServer calls endpoint.start() inside its own
// callback, and the other only asserts a 400 that the transport produces
// before dispatch ever happens.

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_http/rpc_dart_http.dart';
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

final class _Contract extends RpcResponderContract {
  _Contract() : super('Svc');

  @override
  void setup() {
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'echo',
      handler: (request, {RpcContext? context}) async => 'echo-ok'.rpc,
      requestCodec: _codec,
      responseCodec: _codec,
    );
  }
}

/// Boots a server whose callback optionally starts the endpoint itself, and
/// returns what a single call produced.
Future<String> _callThrough({required bool appCallsStart}) async {
  final server = RpcHttpServer(
    host: '127.0.0.1',
    port: 0,
    onEndpointCreated: (endpoint) {
      endpoint.registerServiceContract(_Contract());
      if (appCallsStart) endpoint.start();
    },
  );
  await server.start();
  await server.afterModulesStart();
  addTearDown(server.stop);

  final client = RpcHttpCallerTransport(
    baseUrl: 'http://127.0.0.1:${server.actualPort}',
  );
  final caller = RpcCallerEndpoint(transport: client);

  try {
    final r = await caller
        .unaryRequest<RpcString, RpcString>(
          serviceName: 'Svc',
          methodName: 'echo',
          request: 'x'.rpc,
          requestCodec: _codec,
          responseCodec: _codec,
        )
        .timeout(const Duration(seconds: 5));
    // Only close on the success path. Closing an endpoint with a timed-out
    // call still in flight raises RpcCancelledException into the root zone --
    // Future.timeout abandons the await, not the work -- which would take the
    // whole test runner down rather than fail this test.
    await caller.close();
    await client.close();
    return r.value;
  } on TimeoutException {
    return 'HUNG';
  }
}

void main() {
  test('the server starts its own endpoint', () async {
    expect(
      await _callThrough(appCallsStart: false),
      'echo-ok',
      reason:
          'the endpoint was created and handed to onEndpointCreated but never '
          'started, so the responder pipeline never subscribed and every call '
          'hung with no error on either side',
    );
  });

  test('GUARD: an app that also starts it is unaffected', () async {
    // startResponderListening() guards on _respIsListening precisely because
    // the http2 server and the shipped examples both start the endpoint, so a
    // double start must stay a no-op rather than subscribe twice.
    expect(await _callThrough(appCallsStart: true), 'echo-ok');
  });

  test('GUARD: a double start does not double-deliver requests', () async {
    // The sharp edge behind that guard: two subscriptions on the transport's
    // broadcast stream deliver every frame twice, which only a shape that
    // ACCUMULATES requests can see. Counting handler invocations across
    // several calls catches it where a single unary call would not.
    var handled = 0;
    final contract = _CountingContract(() => handled++);

    final server = RpcHttpServer(
      host: '127.0.0.1',
      port: 0,
      onEndpointCreated: (endpoint) {
        endpoint.registerServiceContract(contract);
        endpoint.start();
      },
    );
    await server.start();
    await server.afterModulesStart();
    addTearDown(server.stop);

    final client = RpcHttpCallerTransport(
      baseUrl: 'http://127.0.0.1:${server.actualPort}',
    );
    final caller = RpcCallerEndpoint(transport: client);
    addTearDown(() async {
      await caller.close();
      await client.close();
    });

    for (var i = 0; i < 5; i++) {
      await caller
          .unaryRequest<RpcString, RpcString>(
            serviceName: 'Svc',
            methodName: 'count',
            request: 'x'.rpc,
            requestCodec: _codec,
            responseCodec: _codec,
          )
          .timeout(const Duration(seconds: 5));
    }

    expect(handled, 5, reason: 'each call must reach the handler exactly once');
  });
}

final class _CountingContract extends RpcResponderContract {
  _CountingContract(this.onCall) : super('Svc');

  final void Function() onCall;

  @override
  void setup() {
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'count',
      handler: (request, {RpcContext? context}) async {
        onCall();
        return 'counted'.rpc;
      },
      requestCodec: _codec,
      responseCodec: _codec,
    );
  }
}
