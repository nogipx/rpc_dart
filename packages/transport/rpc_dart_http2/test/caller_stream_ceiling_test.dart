// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// RpcChannelTransport.createStream() refuses past policy.maxActiveStreams with
// "Too many active streams". The HTTP/2 caller's createStream() only
// incremented a counter, so the same configuration was inert here -- silently.
//
// Measured with a client at maxActiveStreams: 5 against a permissive server,
// 500 concurrent unary calls:
//
//   before: 500 admitted, 0 refused, client health activeStreams=500
//   after :   5 admitted, 495 refused with "Too many active streams"
//
// 500 HTTP/2 streams, 500 subscriptions and 500 stream controllers against a
// ceiling of 5, with no error anywhere. HTTP/2's own
// SETTINGS_MAX_CONCURRENT_STREAMS does not cover for it either, because
// RpcHttp2Server never derives that from the policy.
//
// The count is kept over reserved ids rather than over `_activeStreams`: an id
// only lands in the latter once sendMetadata opens the HTTP/2 stream, so a
// burst of createStream() calls would all pass before the first got that far.

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
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'echo',
      handler: (request, {RpcContext? context}) async => 'echo-ok'.rpc,
      requestCodec: _codec,
      responseCodec: _codec,
    );
  }
}

/// A client with [clientMax] against a deliberately permissive server, so the
/// ceiling under test is the caller's own.
Future<({RpcCallerEndpoint caller, RpcHttp2CallerTransport client})> _connect(
  int clientMax,
) async {
  final server = RpcHttp2Server(
    host: '127.0.0.1',
    port: 0,
    securityPolicy: const RpcSecurityPolicy(maxActiveStreams: 100000),
    onEndpointCreated: (e) => e.registerServiceContract(_Contract()),
  );
  await server.start();

  final client = await RpcHttp2CallerTransport.connect(
    host: '127.0.0.1',
    port: server.port,
    policy: RpcSecurityPolicy(maxActiveStreams: clientMax),
  );
  final caller = RpcCallerEndpoint(transport: client);

  addTearDown(() async {
    if (!_gate.isCompleted) _gate.complete();
    await caller.close();
    await client.close();
    await server.stop();
  });

  return (caller: caller, client: client);
}

Future<Object> _call(RpcCallerEndpoint caller, String method) => caller
    .unaryRequest<RpcString, RpcString>(
      serviceName: 'Svc',
      methodName: method,
      request: 'x'.rpc,
      requestCodec: _codec,
      responseCodec: _codec,
    )
    .then<Object>((r) => r.value, onError: (Object e) => e);

void main() {
  setUp(() => _gate = Completer<void>());
  tearDown(() {
    if (!_gate.isCompleted) _gate.complete();
  });

  test('a caller cannot exceed its own maxActiveStreams', () async {
    final c = await _connect(5);

    final calls = [for (var i = 0; i < 500; i++) _call(c.caller, 'park')];
    await Future<void>.delayed(const Duration(seconds: 2));

    expect(
      (await c.client.health()).details['activeStreams'],
      lessThanOrEqualTo(5),
      reason:
          'createStream only incremented a counter, so the configured ceiling '
          'was inert and 500 streams were opened against a limit of 5',
    );

    _gate.complete();
    final results = await Future.wait(
      calls,
    ).timeout(const Duration(seconds: 30), onTimeout: () => const []);

    final refused = results
        .where((r) => r.toString().contains('Too many active streams'))
        .length;
    expect(
      refused,
      greaterThan(0),
      reason:
          'refusals must say why, in the same words as every other '
          'transport',
    );
    // Nothing may fail for any OTHER reason -- a ceiling that poisons the
    // connection would also "bound" concurrency.
    final unexplained = results
        .where((r) => r is! String && !r.toString().contains('Too many active'))
        .toList();
    expect(unexplained, isEmpty);
  });

  test('slots are released as calls finish', () async {
    // GUARD against the obvious wrong fix: a ceiling that never frees up would
    // pass the test above and wedge the transport after the first batch.
    final c = await _connect(5);

    for (var round = 0; round < 10; round++) {
      final batch = await Future.wait([
        for (var i = 0; i < 5; i++) _call(c.caller, 'echo'),
      ]);
      expect(
        batch,
        everyElement('echo-ok'),
        reason: 'round $round was refused; reservations are not being released',
      );
    }

    final details = (await c.client.health()).details;
    expect(details['activeStreams'], 0);
    expect(details['pendingSubscriptions'], 0);
  });

  test('CONTROL: a generous ceiling refuses nothing', () async {
    final c = await _connect(1000);

    final results = await Future.wait([
      for (var i = 0; i < 50; i++) _call(c.caller, 'echo'),
    ]).timeout(const Duration(seconds: 30));

    expect(results, everyElement('echo-ok'));
  });
}
