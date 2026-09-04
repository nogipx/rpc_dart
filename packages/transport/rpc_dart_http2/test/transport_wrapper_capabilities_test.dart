// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// RpcHttp2Server.transportWrapper lets an application substitute the transport
// the endpoint sees. The endpoint layers find optional capabilities with `is`
// checks and fall back to a default when the check fails -- silently -- so the
// obvious decorator (implement IRpcTransport, forward every method) removed
// them, and the responder pipeline read `const RpcSecurityPolicy()` instead of
// the policy the server was configured with.
//
// The same hole c511e3fc closed inside the library, reopened from outside, with
// nothing to see: the wrapper compiles and every call works.
//
// Measured against `maxActiveStreams: 3`, a peer opening 60 concurrent streams:
//
//   no wrapper       3 / 60 admitted
//   plain wrapper   60 / 60      ->   3 / 60
//
// A decorator that wants to CHANGE the policy declares IRpcSecurityPolicyAware
// itself, which is the only way to express that intent -- so one that declares
// nothing is an oversight, and restoring is what its author meant.

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

/// Forwards every [IRpcTransport] member and declares nothing else -- what a
/// metrics or auth decorator looks like when written the obvious way.
class _CountingTransport implements IRpcTransport {
  _CountingTransport(this.inner);
  final IRpcTransport inner;
  int metadataSends = 0;

  @override
  bool get isClient => inner.isClient;
  @override
  bool get isClosed => inner.isClosed;
  @override
  bool get supportsZeroCopy => inner.supportsZeroCopy;
  @override
  Stream<RpcTransportMessage> get incomingMessages => inner.incomingMessages;
  @override
  Stream<RpcTransportMessage> getMessagesForStream(int id) =>
      inner.getMessagesForStream(id);
  @override
  int createStream() => inner.createStream();
  @override
  bool releaseStreamId(int id) => inner.releaseStreamId(id);
  @override
  Future<void> sendMetadata(int id, RpcMetadata m, {bool endStream = false}) {
    metadataSends++;
    return inner.sendMetadata(id, m, endStream: endStream);
  }

  @override
  Future<void> sendMessage(int id, Uint8List d, {bool endStream = false}) =>
      inner.sendMessage(id, d, endStream: endStream);
  @override
  Future<void> sendDirectObject(int id, Object o, {bool endStream = false}) =>
      inner.sendDirectObject(id, o, endStream: endStream);
  @override
  Future<void> finishSending(int id) => inner.finishSending(id);
  @override
  Future<RpcHealthStatus> health() => inner.health();
  @override
  Future<RpcHealthStatus> reconnect() => inner.reconnect();
  @override
  Future<void> close() => inner.close();
}

/// A decorator that deliberately declares its own, deliberately different,
/// policy. This one must be left exactly as it is.
class _OpinionatedTransport extends _CountingTransport
    implements IRpcSecurityPolicyAware {
  _OpinionatedTransport(super.inner);

  @override
  RpcSecurityPolicy get securityPolicy =>
      const RpcSecurityPolicy(maxActiveStreams: 11);
}

/// Runs 60 concurrent parked calls against a server capped at 3 and reports
/// what the responder admitted.
Future<({int open, IRpcTransport transport, _CountingTransport? wrapper})> _run(
  IRpcTransport Function(IRpcTransport inner)? wrap,
) async {
  _CountingTransport? built;
  RpcResponderEndpoint? serverEndpoint;

  final server = RpcHttp2Server(
    host: '127.0.0.1',
    port: 0,
    securityPolicy: const RpcSecurityPolicy(maxActiveStreams: 3),
    transportWrapper: wrap == null
        ? null
        : (inner, _) {
            final w = wrap(inner);
            if (w is _CountingTransport) built = w;
            return w;
          },
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

  final open = serverEndpoint!.collectEndpointMetrics()['openStreams'] as int;
  final transport = serverEndpoint!.transport;

  _gate.complete();
  await Future.wait(
    calls,
  ).timeout(const Duration(seconds: 10), onTimeout: () => const []);
  await caller.close();
  await client.close();
  await server.stop();

  return (open: open, transport: transport, wrapper: built);
}

void main() {
  setUp(() => _gate = Completer<void>());
  tearDown(() {
    if (!_gate.isCompleted) _gate.complete();
  });

  test('CONTROL: with no wrapper the ceiling holds', () async {
    final r = await _run(null);
    expect(r.open, lessThanOrEqualTo(3));
    expect(r.transport, isA<IRpcSecurityPolicyAware>());
  });

  test('a wrapper that declares nothing keeps the ceiling', () async {
    final r = await _run(_CountingTransport.new);
    expect(
      r.open,
      lessThanOrEqualTo(3),
      reason:
          'the decorator dropped IRpcSecurityPolicyAware, so the pipeline fell '
          'back to the default ceiling and admitted every stream',
    );
    expect(r.transport, isA<IRpcSecurityPolicyAware>());
  });

  test('the wrapper is still the one doing the work', () async {
    // GUARD: restoring the capabilities must not route calls around the
    // decorator -- it would still compile and still cap streams, while
    // silently disabling whatever the wrapper was written to do.
    final r = await _run(_CountingTransport.new);
    expect(r.wrapper, isNotNull);
    expect(
      r.wrapper!.metadataSends,
      greaterThan(0),
      reason: 'responses must still travel through the decorator',
    );
  });

  test('a wrapper with its own policy is left alone', () async {
    // GUARD: declaring IRpcSecurityPolicyAware is the only way to express
    // "I mean a different policy", so it must win over the inner one.
    final r = await _run(_OpinionatedTransport.new);
    expect(
      (r.transport as IRpcSecurityPolicyAware).securityPolicy.maxActiveStreams,
      11,
    );
    expect(r.open, greaterThan(3));
  });
}
