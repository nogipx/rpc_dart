// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// The endpoint layers discover a transport's capabilities with `is` checks:
// the responder pipeline reads maxActiveStreams / halfOpenStreamTimeout through
// IRpcSecurityPolicyAware, the stream parsers read maxMessageLengthBytes the
// same way, and client-stream credit is deferred through IRpcFlowControlled.
// A transport that answers neither gets `const RpcSecurityPolicy()` and credit
// returned on arrival.
//
// Both websocket transports wrap an RpcChannelTransport that implements both
// interfaces, and both were built with the policy the application configured --
// but the wrappers only declared IRpcTransport, so none of it was visible.
//
// Measured against a websocket server configured `maxActiveStreams: 3`, with a
// permissive client so the client's own limiter is not what is being tested:
//
//   before: 200 of 200 concurrent streams admitted
//   after :   3 of 200

import 'dart:async';
import 'dart:io';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_websocket/rpc_dart_websocket.dart';
import 'package:test/test.dart';
import 'package:web_socket_channel/io.dart';

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

  test('a websocket server honours the maxActiveStreams it was given', () async {
    final incoming = StreamController<IOWebSocketChannel>.broadcast();
    final httpServer = await HttpServer.bind('127.0.0.1', 0);
    httpServer.transform(WebSocketTransformer()).listen((ws) {
      incoming.add(IOWebSocketChannel(ws));
    });
    final url = Uri.parse('ws://${httpServer.address.host}:${httpServer.port}');

    final accepted = incoming.stream.first;
    final client = await RpcWebSocketCallerTransport.connect(
      url,
      // Permissive, so the ceiling under test is the server's.
      policy: const RpcSecurityPolicy(maxActiveStreams: 100000),
    );
    final serverTransport = RpcWebSocketResponderTransport(
      await accepted,
      policy: const RpcSecurityPolicy(maxActiveStreams: 3),
    );

    final responder = RpcResponderEndpoint(transport: serverTransport);
    responder.registerServiceContract(_Contract());
    responder.start();
    final caller = RpcCallerEndpoint(transport: client);

    addTearDown(() async {
      if (!_gate.isCompleted) _gate.complete();
      await caller.close();
      await responder.close();
      await client.close();
      await serverTransport.close();
      await incoming.close();
      await httpServer.close(force: true);
    });

    final calls = <Future<Object>>[
      for (var i = 0; i < 200; i++)
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
      responder.collectEndpointMetrics()['openStreams'],
      lessThanOrEqualTo(3),
      reason:
          'the pipeline could not see the policy, so it fell back to the '
          'default ceiling and admitted every stream the peer opened',
    );

    // The capabilities the endpoint layers look for, asserted on real
    // transports and after the behaviour they govern.
    expect(client, isA<IRpcSecurityPolicyAware>());
    expect(client, isA<IRpcFlowControlled>());
    expect(serverTransport, isA<IRpcSecurityPolicyAware>());
    expect(serverTransport, isA<IRpcFlowControlled>());
    expect(
      (serverTransport as IRpcSecurityPolicyAware)
          .securityPolicy
          .maxActiveStreams,
      3,
      reason: 'the wrapper must report its own policy, not a default one',
    );

    // The refused calls must be told why rather than left hanging -- guards the
    // wrong fix of a ceiling that simply drops what it will not serve.
    _gate.complete();
    final results = await Future.wait(calls);
    expect(
      results.whereType<RpcStatusException>().where(
        (e) => e.statusCode == RpcStatus.resourceExhausted,
      ),
      isNotEmpty,
    );
  });
}
