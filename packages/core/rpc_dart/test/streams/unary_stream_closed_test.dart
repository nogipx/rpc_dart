// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// UnaryCaller subscribed to its response stream with onError but NO onDone. So
// when the stream ended without a response -- transport closed, responder shut
// down, connection lost -- nothing ever completed the caller's completer, and
// the call hung until the 60s fallback, or forever if it had a longer deadline.
//
// Found by tearing each layer down under four in-flight calls, one per shape:
//
//   caller.close()      settled=4/4  (all RpcCancelledException)
//   responder.close()   settled=3/4  HUNG=[unary]
//   client transport    settled=3/4  HUNG=[unary]
//   server transport    settled=3/4  HUNG=[unary]
//   both transports     settled=3/4  HUNG=[unary]
//
// Unary was the only shape that hung, every time. ClientStreamCaller has always
// had this handler and reports UNAVAILABLE; unary simply lacked it.

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

final class _Contract extends RpcResponderContract {
  _Contract() : super('Svc');

  @override
  void setup() {
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'slow',
      handler: (r, {RpcContext? context}) async {
        await Completer<void>().future;
        return r;
      },
      requestCodec: _codec,
      responseCodec: _codec,
    );
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'echo',
      handler: (r, {RpcContext? context}) async => r,
      requestCodec: _codec,
      responseCodec: _codec,
    );
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'boom',
      handler: (r, {RpcContext? context}) async =>
          throw RpcStatusException(RpcStatus.notFound, 'gone'),
      requestCodec: _codec,
      responseCodec: _codec,
    );
  }
}

typedef _Rig = ({
  RpcChannelTransport client,
  RpcChannelTransport server,
  RpcCallerEndpoint caller,
  RpcResponderEndpoint responder,
});

_Rig _connect() {
  final (client, server) = RpcChannelTransport.pair();
  final caller = RpcCallerEndpoint(transport: client);
  final responder = RpcResponderEndpoint(transport: server);
  responder.registerServiceContract(_Contract());
  responder.start();
  return (client: client, server: server, caller: caller, responder: responder);
}

Future<RpcString> _call(_Rig rig, String method, {RpcContext? ctx}) {
  return rig.caller.unaryRequest<RpcString, RpcString>(
    serviceName: 'Svc',
    methodName: method,
    request: 'a'.rpc,
    requestCodec: _codec,
    responseCodec: _codec,
    context: ctx,
  );
}

void main() {
  group('an in-flight unary call fails when its stream ends', () {
    test('the responder is closed', () async {
      final rig = _connect();
      final call = _call(rig, 'slow');

      await Future<void>.delayed(const Duration(milliseconds: 100));
      await rig.responder.close();

      await expectLater(
        call.timeout(
          const Duration(seconds: 5),
          onTimeout: () => fail('the call hung after the responder closed'),
        ),
        throwsA(isA<RpcStatusException>()),
      );

      await rig.caller.close();
      await rig.client.close();
      await rig.server.close();
    });

    test('the transport is closed', () async {
      final rig = _connect();
      final call = _call(rig, 'slow');

      await Future<void>.delayed(const Duration(milliseconds: 100));
      await rig.server.close();

      await expectLater(
        call.timeout(
          const Duration(seconds: 5),
          onTimeout: () => fail('the call hung after the transport closed'),
        ),
        throwsA(isA<RpcStatusException>()),
      );

      await rig.caller.close();
      await rig.client.close();
    });

    test('reported as UNAVAILABLE, not a made-up success', () async {
      final rig = _connect();
      final call = _call(rig, 'slow');

      await Future<void>.delayed(const Duration(milliseconds: 100));
      await rig.server.close();

      await expectLater(
        call.timeout(const Duration(seconds: 5)),
        throwsA(
          isA<RpcStatusException>().having(
            (e) => e.statusCode,
            'statusCode',
            RpcStatus.unavailable,
          ),
        ),
      );

      await rig.caller.close();
      await rig.client.close();
    });

    test('a close on the deadline boundary reports the deadline', () async {
      // Same handler as ClientStreamCaller: the deadline outranks a bare
      // close, tested with remainingTime because isExpired is strict.
      final rig = _connect();
      final start = DateTime.now();
      final deadline = start.add(const Duration(seconds: 30));
      var now = start;
      final ctx = RpcContext.withDeadline(deadline).withClock(() => now);

      final call = _call(rig, 'slow', ctx: ctx);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      now = deadline; // exactly the boundary: isExpired false, remaining zero
      await rig.server.close();

      await expectLater(
        call.timeout(const Duration(seconds: 5)),
        throwsA(isA<RpcDeadlineExceededException>()),
      );

      await rig.caller.close();
      await rig.client.close();
    });
  });

  group('ordinary outcomes are unchanged', () {
    test('a successful call still returns its response', () async {
      final rig = _connect();
      expect((await _call(rig, 'echo')).value, 'a');
      await rig.caller.close();
      await rig.responder.close();
      await rig.client.close();
      await rig.server.close();
    });

    test('a handler error still surfaces its status', () async {
      final rig = _connect();
      await expectLater(
        _call(rig, 'boom'),
        throwsA(
          isA<RpcStatusException>().having(
            (e) => e.statusCode,
            'statusCode',
            RpcStatus.notFound,
          ),
        ),
      );
      await rig.caller.close();
      await rig.responder.close();
      await rig.client.close();
      await rig.server.close();
    });

    test('many sequential calls still settle', () async {
      final rig = _connect();
      for (var i = 0; i < 20; i++) {
        expect((await _call(rig, 'echo')).value, 'a');
      }
      expect(rig.caller.collectEndpointMetrics()['pendingRequests'], 0);
      await rig.caller.close();
      await rig.responder.close();
      await rig.client.close();
      await rig.server.close();
    });
  });
}
