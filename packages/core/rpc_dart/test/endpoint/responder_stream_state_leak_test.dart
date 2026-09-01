// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// Tearing a responder stream down does not stop the peer. A unary call's
// request payload races the server's error trailer, so for an unregistered
// method the sequence was:
//
//   1. metadata frame -> method not found -> send UNIMPLEMENTED, _cleanupStream
//   2. payload frame  -> _respStreams.obtain() RESURRECTS the state
//   3. the revived entry has no method, so the frame is buffered pre-method
//      and nothing ever cleans it up again.
//
// One leaked RpcResponderStreamState per call -- holding its cached context,
// metadata and buffered frames -- driven entirely by client input, so any
// client (or a version-skewed one calling a method the server lacks) could
// grow the server's map without bound.

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

final class _EchoContract extends RpcResponderContract {
  _EchoContract() : super('Svc');

  @override
  void setup() {
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'echo',
      handler: (request, {RpcContext? context}) async => request,
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

  setUp(() {
    (client, server) = RpcChannelTransport.pair();
    caller = RpcCallerEndpoint(transport: client);
    responder = RpcResponderEndpoint(transport: server);
    responder.registerServiceContract(_EchoContract());
    responder.start();
  });

  tearDown(() async {
    await caller.close();
    await responder.close();
    await client.close();
    await server.close();
  });

  int openStreams() =>
      responder.collectResponderMetrics()['openStreams']! as int;

  Future<void> settle() =>
      Future<void>.delayed(const Duration(milliseconds: 400));

  test('calls to an unregistered method do not leak stream state', () async {
    expect(openStreams(), 0);

    for (var i = 0; i < 10; i++) {
      await expectLater(
        caller.unaryRequest<RpcString, RpcString>(
          serviceName: 'Svc',
          methodName: 'missing',
          request: 'x'.rpc,
          requestCodec: _codec,
          responseCodec: _codec,
        ),
        throwsA(anything),
      );
    }

    await settle();
    expect(
      openStreams(),
      0,
      reason: 'each UNIMPLEMENTED call leaked one stream state before the fix',
    );
  });

  test('successful calls still work and leave no state behind', () async {
    for (var i = 0; i < 5; i++) {
      final response = await caller.unaryRequest<RpcString, RpcString>(
        serviceName: 'Svc',
        methodName: 'echo',
        request: 'hello'.rpc,
        requestCodec: _codec,
        responseCodec: _codec,
      );
      expect(response.value, 'hello');
    }

    await settle();
    expect(openStreams(), 0);
  });

  test('a rejected stream does not poison later calls', () async {
    // The guard that stops a torn-down stream from being resurrected must not
    // block a genuinely new call, which always opens with a methodPath frame.
    await expectLater(
      caller.unaryRequest<RpcString, RpcString>(
        serviceName: 'Svc',
        methodName: 'missing',
        request: 'x'.rpc,
        requestCodec: _codec,
        responseCodec: _codec,
      ),
      throwsA(anything),
    );

    final response = await caller.unaryRequest<RpcString, RpcString>(
      serviceName: 'Svc',
      methodName: 'echo',
      request: 'still-works'.rpc,
      requestCodec: _codec,
      responseCodec: _codec,
    );
    expect(response.value, 'still-works');

    await settle();
    expect(openStreams(), 0);
  });
}
