// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// _prepareCallerContext used to register a call's cancellation token the moment
// the entry point was CALLED. That is right for unary and client-stream, which
// start immediately -- but serverStream() and bidirectionalStream() return COLD
// streams. Nothing is on the wire until something subscribes, and the matching
// untrack only runs from the stream's onDone/onCancel. A stream that was built
// and then dropped therefore leaked its token forever:
//
//   baseline                          pending=0
//   after 10 unlistened serverStream: pending=10
//   after 10 unlistened bidi:         pending=20
//
// The cost is not only memory. _callerTokens backs the public
// isMethodActive/getActiveCallsCount/cancelMethod API and the pendingRequests
// health metric, so every one of them reported a call that never happened, with
// no way to clear it short of cancelAllMethods().
//
// Tracking now starts when the call does: on first listen.

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
      handler: (request, {RpcContext? context}) async => request,
      requestCodec: _codec,
      responseCodec: _codec,
    );

    addServerStreamMethod<RpcString, RpcString>(
      methodName: 'few',
      handler: (request, {RpcContext? context}) async* {
        yield 'a'.rpc;
        yield 'b'.rpc;
      },
      requestCodec: _codec,
      responseCodec: _codec,
    );

    addBidirectionalMethod<RpcString, RpcString>(
      methodName: 'mirror',
      handler: (requests, {RpcContext? context}) async* {
        await for (final r in requests) {
          yield r;
        }
      },
      requestCodec: _codec,
      responseCodec: _codec,
    );

    addServerStreamMethod<RpcString, RpcString>(
      methodName: 'endless',
      handler: (request, {RpcContext? context}) async* {
        while (true) {
          yield 'v'.rpc;
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
      },
      requestCodec: _codec,
      responseCodec: _codec,
    );
  }
}

void main() {
  late RpcChannelTransport client;
  late RpcChannelTransport server;
  late RpcCallerEndpoint caller;
  late RpcResponderEndpoint responder;

  int pending() => caller.collectEndpointMetrics()['pendingRequests'] as int;

  setUp(() {
    final pair = RpcChannelTransport.pair();
    client = pair.$1;
    server = pair.$2;
    caller = RpcCallerEndpoint(transport: client);
    responder = RpcResponderEndpoint(transport: server);
    responder.registerServiceContract(_Contract());
    responder.start();
  });

  tearDown(() async {
    await caller.close();
    await responder.close();
    await client.close();
    await server.close();
  });

  test('an unlistened server stream tracks nothing', () async {
    for (var i = 0; i < 10; i++) {
      caller.serverStream<RpcString, RpcString>(
        serviceName: 'Svc',
        methodName: 'few',
        request: 'x'.rpc,
        requestCodec: _codec,
        responseCodec: _codec,
      );
    }
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(pending(), 0, reason: 'cold streams leaked their tokens');
    expect(caller.getCancellationTokensForMethod('Svc', 'few'), isEmpty);
  });

  test('an unlistened bidirectional stream tracks nothing', () async {
    for (var i = 0; i < 10; i++) {
      caller.bidirectionalStream<RpcString, RpcString>(
        serviceName: 'Svc',
        methodName: 'mirror',
        requests: const Stream<RpcString>.empty(),
        requestCodec: _codec,
        responseCodec: _codec,
      );
    }
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(pending(), 0, reason: 'cold bidi streams leaked their tokens');
  });

  test('isMethodActive does not lie about a stream nobody listened to', () {
    final contract = _CallerContract(caller);
    contract.buildButDropAServerStream();

    expect(
      contract.isMethodActive('few'),
      isFalse,
      reason: 'a cold stream is not an active call',
    );
    expect(contract.getActiveCallsCount('few'), 0);
  });

  test('a listened stream is still tracked while it runs', () async {
    final sub = caller
        .serverStream<RpcString, RpcString>(
          serviceName: 'Svc',
          methodName: 'endless',
          request: 'x'.rpc,
          requestCodec: _codec,
          responseCodec: _codec,
        )
        .listen((_) {}, onError: (Object _) {});

    // Tracking must begin on listen, or cancelMethod() could not reach it.
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(pending(), 1, reason: 'a running stream must be cancellable');
    expect(caller.cancelMethod('Svc', 'endless'), 1);

    await sub.cancel();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(pending(), 0);
  });

  test('consumed calls of every shape release their tracking', () async {
    await caller.unaryRequest<RpcString, RpcString>(
      serviceName: 'Svc',
      methodName: 'echo',
      request: 'x'.rpc,
      requestCodec: _codec,
      responseCodec: _codec,
    );

    await caller
        .serverStream<RpcString, RpcString>(
          serviceName: 'Svc',
          methodName: 'few',
          request: 'x'.rpc,
          requestCodec: _codec,
          responseCodec: _codec,
        )
        .toList();

    await caller
        .bidirectionalStream<RpcString, RpcString>(
          serviceName: 'Svc',
          methodName: 'mirror',
          requests: Stream<RpcString>.value('x'.rpc),
          requestCodec: _codec,
          responseCodec: _codec,
        )
        .toList();

    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(pending(), 0);
  });
}

/// Exercises the public contract-level API that reads _callerTokens.
final class _CallerContract extends RpcCallerContract {
  _CallerContract(RpcCallerEndpoint endpoint) : super('Svc', endpoint);

  void buildButDropAServerStream() {
    callServerStream<RpcString, RpcString>(
      methodName: 'few',
      request: 'x'.rpc,
      requestCodec: _codec,
      responseCodec: _codec,
    );
  }
}
