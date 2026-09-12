// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// `non_binary_frame_test.dart` checks the CHANNEL: a text frame is reported and
// the connection survives. Both were true and the calls died anyway.
//
// RpcChannelTransport answers a channel error into every per-stream controller
// -- "a connection-level failure is the answer to every call in flight" -- so
// the plain RpcException the channel sent for one stray frame failed every live
// call with a non-retryable error, over a connection that kept working. An
// app-level keepalive from a proxy was enough.
//
// Measured with two unary calls parked in the handler:
//
//   no text      ok, ok                    connection alive
//   text frame   RpcException, RpcException  connection alive   <- before
//
// The fix marks it IRpcAdvisoryChannelError, so it stops at the connection
// stream, where both endpoints log it.

import 'dart:async';
import 'dart:io';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_websocket/rpc_dart_websocket.dart';
import 'package:test/test.dart';
import 'package:web_socket_channel/io.dart';

final _codec = RpcCodec(RpcString.fromJson);

final class _SlowContract extends RpcResponderContract {
  _SlowContract(this.gate) : super('Svc');

  final Completer<void> gate;

  @override
  void setup() {
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'Wait',
      handler: (req, {RpcContext? context}) async {
        await gate.future;
        return 'ok:${req.value}'.rpc;
      },
      requestCodec: _codec,
      responseCodec: _codec,
    );
  }
}

typedef _Rig = ({
  RpcCallerEndpoint caller,
  RpcChannelTransport clientTransport,
  WebSocket serverWs,
  Completer<void> gate,
});

Future<_Rig> _rig() async {
  final accepted = Completer<WebSocket>();
  final server = await HttpServer.bind('127.0.0.1', 0);
  server.transform(WebSocketTransformer()).listen((ws) {
    if (!accepted.isCompleted) accepted.complete(ws);
  });
  addTearDown(() => server.close(force: true));

  final clientWs = await WebSocket.connect(
    'ws://${server.address.host}:${server.port}',
  );
  final serverWs = await accepted.future;

  final clientTransport = RpcChannelTransport.fromChannel(
    channel: RpcWebSocketChannel(IOWebSocketChannel(clientWs)),
    isClient: true,
  );
  final serverTransport = RpcChannelTransport.fromChannel(
    channel: RpcWebSocketChannel(IOWebSocketChannel(serverWs)),
    isClient: false,
  );
  addTearDown(clientTransport.close);
  addTearDown(serverTransport.close);

  final gate = Completer<void>();
  final caller = RpcCallerEndpoint(transport: clientTransport);
  final responder = RpcResponderEndpoint(transport: serverTransport);
  addTearDown(caller.close);
  addTearDown(responder.close);
  // The gate is NOT completed on teardown. Waking a parked handler after the
  // socket is gone makes it answer into a closed sink, which throws out of
  // `RpcWebSocketChannel.send` where nothing catches it -- a real defect, and a
  // different one. Leaving the handler parked keeps it out of this test.
  responder.registerServiceContract(_SlowContract(gate));
  responder.start();

  return (
    caller: caller,
    clientTransport: clientTransport,
    serverWs: serverWs,
    gate: gate,
  );
}

Future<String> _call(RpcCallerEndpoint caller, String tag) => caller
    .unaryRequest<RpcString, RpcString>(
      serviceName: 'Svc',
      methodName: 'Wait',
      request: tag.rpc,
      requestCodec: _codec,
      responseCodec: _codec,
    )
    .timeout(const Duration(seconds: 10))
    .then((r) => r.value);

void main() {
  // WITNESS: the stray frame must not be the answer to calls it has nothing to
  // do with.
  test('a text frame does not fail the calls in flight', () async {
    final rig = await _rig();

    final a = _call(rig.caller, 'a');
    final b = _call(rig.caller, 'b');
    // Both calls are parked in the handler before anything else happens.
    await Future<void>.delayed(const Duration(milliseconds: 400));

    rig.serverWs.add('an app-level keepalive from a proxy');
    await Future<void>.delayed(const Duration(milliseconds: 300));

    rig.gate.complete();
    expect(await a, 'ok:a');
    expect(await b, 'ok:b');
    expect(
      rig.clientTransport.isClosed,
      isFalse,
      reason: 'one stray text frame must not tear the connection down',
    );
  });

  // GUARD: the report still travels to the connection stream, which is where
  // both endpoints log it. Losing this would be the ORIGINAL defect back --
  // silently dropped, nothing anywhere.
  test('the report still reaches the transport incoming stream', () async {
    final rig = await _rig();
    final errors = <Object>[];
    final sub = rig.clientTransport.incomingMessages.listen(
      (_) {},
      onError: errors.add,
    );
    addTearDown(sub.cancel);

    rig.serverWs.add('text');
    await Future<void>.delayed(const Duration(milliseconds: 300));

    expect(errors, hasLength(1));
    expect(errors.first, isA<RpcWebSocketNonBinaryFrame>());
    expect(errors.first, isA<IRpcAdvisoryChannelError>());
    expect(errors.first.toString(), contains('binary'));
  });

  // GUARD: a REAL connection failure must still reach every call in flight.
  // This is the property the fan-out exists for, and the one an over-broad fix
  // would remove.
  test('a connection failure still answers every call in flight', () async {
    final rig = await _rig();

    final a = _call(rig.caller, 'a');
    final b = _call(rig.caller, 'b');
    await Future<void>.delayed(const Duration(milliseconds: 400));

    // 1011 "internal error": the peer said something, so the channel reports it
    // as a connection-level status rather than ending the stream quietly.
    await rig.serverWs.close(1011, 'server exploded');

    await expectLater(a, throwsA(isA<RpcStatusException>()));
    await expectLater(b, throwsA(isA<RpcStatusException>()));
  });
}
