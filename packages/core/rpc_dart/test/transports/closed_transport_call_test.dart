// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// A call made on a CLOSED RpcChannelTransport used to raise an UNHANDLED async
// error, which ends the process outside a guarded zone.
//
// getMessagesForStream returned `const Stream.empty()`, done the moment it is
// listened to. The unary caller's onDone ("response stream closed without a
// response") therefore ran while the application was still inside
// unaryRequest() and had not yet attached to the future -- and completing a
// future with an error that has no listener AT THAT MOMENT is what Dart
// reports as unhandled. Attaching afterwards does not retract it.
//
// Reproduced end to end in rpc_dart_isolate: the worker isolate dies mid-call
// (any unhandled async error in worker code), the host correctly fails the
// in-flight call and reports isClosed / "Transport is closed" -- and then ONE
// MORE call killed the host:
//
//   before: Unhandled exception: RpcStatusException(14): Stream closed without
//           receiving response      (no stack frames at all)
//   after : the call throws RpcStatusException(14) like any other failure
//
// The fix deliberately does NOT make createStream() or sendMetadata() throw,
// even though RpcHttpCallerTransport and RpcHttp2CallerTransport both do. This
// transport is documented to stay lenient after close -- "use after close fails
// cleanly (no throw, no delivery)" pins it, and two further tests besides -- so
// only the SHAPE of the per-stream view changed. Those tests pass unchanged.
//
// The error is delivered on a timer rather than a microtask: the caller
// subscribes and only then returns the future the application awaits, all in
// one microtask chain, so a microtask-delivered error still beats the await.

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
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

/// Runs [body] and reports every error that reached the zone without a handler.
Future<List<Object>> _unhandledDuring(Future<void> Function() body) async {
  final unhandled = <Object>[];
  final done = Completer<void>();
  runZonedGuarded(() async {
    try {
      await body();
    } finally {
      if (!done.isCompleted) done.complete();
    }
  }, (error, stack) => unhandled.add(error));
  await done.future;
  // Give any stranded error a turn to be reported.
  await Future<void>.delayed(const Duration(milliseconds: 50));
  return unhandled;
}

void main() {
  test('a call on a closed transport fails cleanly, not unhandled', () async {
    final (client, server) = RpcChannelTransport.pair();
    final responder = RpcResponderEndpoint(transport: server);
    responder.registerServiceContract(_Contract());
    responder.start();
    final caller = RpcCallerEndpoint(transport: client);

    // Warm-up: the pair works.
    expect(
      (await caller.unaryRequest<RpcString, RpcString>(
        serviceName: 'Svc',
        methodName: 'echo',
        request: 'x'.rpc,
        requestCodec: _codec,
        responseCodec: _codec,
      )).value,
      'echo-ok',
    );

    await client.close();

    Object? caught;
    final unhandled = await _unhandledDuring(() async {
      try {
        await caller
            .unaryRequest<RpcString, RpcString>(
              serviceName: 'Svc',
              methodName: 'echo',
              request: 'x'.rpc,
              requestCodec: _codec,
              responseCodec: _codec,
            )
            .timeout(const Duration(seconds: 5));
      } catch (e) {
        caught = e;
      }
    });

    expect(
      unhandled,
      isEmpty,
      reason:
          'the failure landed on a future nobody had attached to yet, so Dart '
          'reported it as unhandled and the process died outside a guarded zone',
    );
    expect(
      caught,
      isA<RpcStatusException>().having(
        (e) => e.statusCode,
        'statusCode',
        RpcStatus.unavailable,
      ),
      reason: 'the caller must still be told the call failed',
    );

    await responder.close();
    await server.close();
  });

  group('GUARD: the documented leniency after close is unchanged', () {
    // These pin the contract the obvious fix would have broken -- adding
    // `if (_closed) throw` to createStream(), as the HTTP callers do.
    late RpcChannelTransport transport;

    setUp(() async {
      final (client, server) = RpcChannelTransport.memoryPair();
      transport = client;
      await server.close();
      await transport.close();
    });

    test('createStream() does not throw', () {
      expect(transport.createStream, returnsNormally);
    });

    test('sending after close completes rather than throwing', () async {
      final streamId = transport.createStream();
      await expectLater(
        transport.sendDirectObject(streamId, 'PING'),
        completes,
      );
      await expectLater(
        transport.sendMetadata(streamId, RpcMetadata([])),
        completes,
      );
    });

    test('releaseStreamId() does not throw', () {
      final streamId = transport.createStream();
      expect(() => transport.releaseStreamId(streamId), returnsNormally);
    });
  });

  test('GUARD: an open transport is unaffected', () async {
    // The changed branch is only reached when closed, but the per-stream view
    // is the hot path for every call, so pin it.
    final (client, server) = RpcChannelTransport.pair();
    final responder = RpcResponderEndpoint(transport: server);
    responder.registerServiceContract(_Contract());
    responder.start();
    final caller = RpcCallerEndpoint(transport: client);

    for (var i = 0; i < 5; i++) {
      expect(
        (await caller.unaryRequest<RpcString, RpcString>(
          serviceName: 'Svc',
          methodName: 'echo',
          request: 'x'.rpc,
          requestCodec: _codec,
          responseCodec: _codec,
        )).value,
        'echo-ok',
        reason: 'round $i',
      );
    }

    await caller.close();
    await responder.close();
    await client.close();
    await server.close();
  });
}
