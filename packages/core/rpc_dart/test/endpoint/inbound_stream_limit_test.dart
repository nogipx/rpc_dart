// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// RpcSecurityPolicy.maxActiveStreams is documented as the max number of
// simultaneously active streams, but it was only ever checked in
// createStream() -- which runs for LOCALLY-initiated calls. Inbound streams,
// the only ones an untrusted peer controls, were never counted, so on a server
// the one limit that mattered bounded nothing.
//
// Measured against a server configured with maxActiveStreams: 3, with a
// permissive client so the client's own limiter was not the thing under test:
//
//   peer opened 500 streams against a server with maxActiveStreams=3
//     calls rejected by client  : 0
//     server activeStreams      : 0     <- transport never counts inbound
//     responder openStreams     : 500
//     responder activeResponders: 500
//
// 500 stream states, contexts, call scopes and responders, each with its own
// controllers and reassembly buffer. Unauthenticated memory exhaustion, on
// every transport without its own concurrency ceiling (HTTP/2 has
// SETTINGS_MAX_CONCURRENT_STREAMS; the channel, websocket and isolate
// transports have nothing).

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

/// Released to let the parked handlers finish.
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

    addUnaryMethod<RpcString, RpcString>(
      methodName: 'echo',
      handler: (request, {RpcContext? context}) async => request,
      requestCodec: _codec,
      responseCodec: _codec,
    );
  }
}

/// A client/server pair whose policies differ, so the server-side ceiling can
/// be tested without the client's own limiter interfering.
({
  RpcChannelTransport client,
  RpcChannelTransport server,
  RpcCallerEndpoint caller,
  RpcResponderEndpoint responder,
})
_connect({required int serverMaxStreams}) {
  final (clientCh, serverCh) = RpcFrameMultiplexedChannel.pair();
  final client = RpcChannelTransport(
    channel: clientCh,
    isClient: true,
    policy: const RpcSecurityPolicy(maxActiveStreams: 100000),
  );
  final server = RpcChannelTransport(
    channel: serverCh,
    isClient: false,
    policy: RpcSecurityPolicy(maxActiveStreams: serverMaxStreams),
  );
  final caller = RpcCallerEndpoint(transport: client);
  final responder = RpcResponderEndpoint(transport: server);
  responder.registerServiceContract(_Contract());
  responder.start();
  return (client: client, server: server, caller: caller, responder: responder);
}

/// Fires [n] calls to [method] without awaiting; returns their futures.
List<Future<Object>> _fire(RpcCallerEndpoint caller, String method, int n) => [
  for (var i = 0; i < n; i++)
    caller
        .unaryRequest<RpcString, RpcString>(
          serviceName: 'Svc',
          methodName: method,
          request: 'x'.rpc,
          requestCodec: _codec,
          responseCodec: _codec,
        )
        .then<Object>((r) => r, onError: (Object e) => e),
];

void main() {
  setUp(() => _gate = Completer<void>());

  tearDown(() {
    if (!_gate.isCompleted) _gate.complete();
  });

  test('a peer cannot open more concurrent streams than the policy', () async {
    final c = _connect(serverMaxStreams: 3);

    final calls = _fire(c.caller, 'park', 200);
    // Let every request reach the wire.
    for (var i = 0; i < 200; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    await Future<void>.delayed(const Duration(milliseconds: 300));

    expect(
      c.responder.collectEndpointMetrics()['openStreams'],
      lessThanOrEqualTo(3),
      reason: 'the peer opened more streams than the policy allows',
    );

    // The refused calls must be told why, not left hanging.
    _gate.complete();
    final results = await Future.wait(calls);
    final exhausted = results
        .whereType<RpcStatusException>()
        .where((e) => e.statusCode == RpcStatus.resourceExhausted)
        .length;
    expect(
      exhausted,
      greaterThan(0),
      reason: 'refused streams must get RESOURCE_EXHAUSTED, not silence',
    );

    await c.caller.close();
    await c.responder.close();
    await c.client.close();
    await c.server.close();
  });

  test('slots are released as streams finish', () async {
    // Guards the obvious wrong fix: a ceiling that never frees up would also
    // pass the test above.
    final c = _connect(serverMaxStreams: 2);

    for (var round = 0; round < 5; round++) {
      final results = await Future.wait(_fire(c.caller, 'echo', 2));
      expect(
        results.whereType<RpcStatusException>(),
        isEmpty,
        reason: 'round $round was refused; slots are not being released',
      );
    }

    expect(c.responder.collectEndpointMetrics()['openStreams'], 0);

    await c.caller.close();
    await c.responder.close();
    await c.client.close();
    await c.server.close();
  });

  test('traffic below the ceiling is untouched', () async {
    final c = _connect(serverMaxStreams: 64);

    final results = await Future.wait(_fire(c.caller, 'echo', 20));
    expect(results.whereType<RpcStatusException>(), isEmpty);

    await c.caller.close();
    await c.responder.close();
    await c.client.close();
    await c.server.close();
  });

  test('a transport without the capability gets the default ceiling', () async {
    // Falling back to 0 would break every call; falling back to the documented
    // default is what keeps a third-party transport working.
    final transport = _PlainTransport();
    final responder = RpcResponderEndpoint(transport: transport);
    responder.registerServiceContract(_Contract());
    responder.start();

    expect(transport, isNot(isA<IRpcSecurityPolicyAware>()));
    // 4096 is the documented default; the endpoint must not refuse stream 1.
    expect(const RpcSecurityPolicy().maxActiveStreams, 4096);

    await responder.close();
  });
}

/// A minimal transport that does NOT implement [IRpcSecurityPolicyAware].
final class _PlainTransport implements IRpcTransport {
  final _incoming = StreamController<RpcTransportMessage>.broadcast();
  var _closed = false;
  var _next = 0;

  @override
  bool get isClient => false;

  @override
  bool get isClosed => _closed;

  @override
  bool get supportsZeroCopy => false;

  @override
  Stream<RpcTransportMessage> get incomingMessages => _incoming.stream;

  @override
  Stream<RpcTransportMessage> getMessagesForStream(int streamId) =>
      _incoming.stream.where((m) => m.streamId == streamId);

  @override
  int createStream() => _next += 2;

  @override
  bool releaseStreamId(int streamId) => true;

  @override
  Future<void> sendMetadata(
    int streamId,
    RpcMetadata metadata, {
    bool endStream = false,
  }) async {}

  @override
  Future<void> sendMessage(
    int streamId,
    Uint8List data, {
    bool endStream = false,
  }) async {}

  @override
  Future<void> sendDirectObject(
    int streamId,
    Object object, {
    bool endStream = false,
  }) async {}

  @override
  Future<void> finishSending(int streamId) async {}

  @override
  Future<void> close() async {
    _closed = true;
    await _incoming.close();
  }

  @override
  Future<RpcHealthStatus> health() async =>
      RpcHealthStatus.healthy(component: 'plain', message: 'ok');

  @override
  Future<RpcHealthStatus> reconnect() async =>
      RpcHealthStatus.degraded(component: 'plain', message: 'no');
}
