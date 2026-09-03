// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// startResponderListening() guarded on _respIsListening but set that flag
// AFTER awaiting the old subscription's cancel and subscribing. `start()`
// returns void and does not await it, so two synchronous start() calls both
// read the guard while it was still false, both suspended on the await, and
// both subscribed. The transport's incoming stream is a BROADCAST, so that is
// two live subscriptions delivering every frame twice -- and the first is
// orphaned, since _respIncomingSub only remembers the second.
//
// Not hypothetical. RpcHttp2Server calls endpoint.start() itself right after
// onEndpointCreated, and both shipped rpc_dart_grpc_reflection examples call
// start() inside that callback, so the framework's own documented wiring
// produced the double subscribe.
//
// Found with grpcurl -- a real gRPC client -- against an HTTP/2 server serving
// all four call shapes. Sending three client-stream messages:
//
//   before: cs:6:x|x|y|y|z|z
//   after : cs:3:x|y|z
//
// Unary and server-streaming hid it: one request frame is deduplicated
// downstream, so only a shape that ACCUMULATES requests exposed the doubling.
// Bidi echoed 1:1 for the same reason. That is why every Dart-side test passed.

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

/// Every request the client-stream handler observed.
final List<String> _seen = [];

/// How many times the unary handler ran.
int _unaryCalls = 0;

final class _Svc extends RpcResponderContract {
  _Svc() : super('Svc');

  @override
  void setup() {
    addClientStreamMethod<RpcString, RpcString>(
      methodName: 'collect',
      handler: (requests, {RpcContext? context}) async {
        await for (final r in requests) {
          _seen.add(r.value);
        }
        return 'n=${_seen.length}'.rpc;
      },
      requestCodec: _codec,
      responseCodec: _codec,
    );

    addUnaryMethod<RpcString, RpcString>(
      methodName: 'once',
      handler: (r, {RpcContext? context}) async {
        _unaryCalls++;
        return 'ok'.rpc;
      },
      requestCodec: _codec,
      responseCodec: _codec,
    );
  }
}

typedef _Harness = ({RpcCallerEndpoint caller, RpcResponderEndpoint responder});

/// Builds a connected pair, calling [starts] times to model a host that starts
/// the endpoint itself while the caller's callback also does.
_Harness _build({required int starts}) {
  final (client, server) = RpcChannelTransport.pair();
  final caller = RpcCallerEndpoint(transport: client);
  final responder = RpcResponderEndpoint(transport: server);
  responder.registerServiceContract(_Svc());
  for (var i = 0; i < starts; i++) {
    responder.start();
  }
  return (caller: caller, responder: responder);
}

Future<String> _collect(RpcCallerEndpoint caller, List<String> items) {
  final call = caller.clientStream<RpcString, RpcString>(
    serviceName: 'Svc',
    methodName: 'collect',
    requestCodec: _codec,
    responseCodec: _codec,
  );
  return call(
    Stream.fromIterable(items.map((s) => s.rpc)),
  ).then((r) => r.value);
}

void main() {
  setUp(() {
    _seen.clear();
    _unaryCalls = 0;
  });

  group('start() called twice', () {
    // WITNESS: three requests arrived six times.
    test('a client-stream handler still sees each request once', () async {
      final h = _build(starts: 2);

      final result = await _collect(h.caller, ['x', 'y', 'z']);

      expect(
        _seen,
        ['x', 'y', 'z'],
        reason:
            'the handler observed ${_seen.length} requests for 3 sent: a '
            'second start() attached a second broadcast subscription',
      );
      expect(result, 'n=3');

      await h.caller.close();
      await h.responder.close();
    });

    // WITNESS: the same doubling reached a unary handler, it was just invisible
    // in the response.
    test('a unary handler runs once per call', () async {
      final h = _build(starts: 2);

      await h.caller.unaryRequest<RpcString, RpcString>(
        serviceName: 'Svc',
        methodName: 'once',
        request: 'x'.rpc,
        requestCodec: _codec,
        responseCodec: _codec,
      );

      expect(
        _unaryCalls,
        1,
        reason: 'the handler ran $_unaryCalls times for one call',
      );

      await h.caller.close();
      await h.responder.close();
    });

    test('three start() calls are still safe', () async {
      final h = _build(starts: 3);

      await _collect(h.caller, ['a', 'b']);

      expect(_seen, ['a', 'b']);

      await h.caller.close();
      await h.responder.close();
    });
  });

  // GUARDS: pass on both sides. The ordinary single-start path must be
  // untouched, or the fix would just be trading one bug for another.
  group('the ordinary single start is unaffected', () {
    test('client stream delivers each request once', () async {
      final h = _build(starts: 1);

      final result = await _collect(h.caller, ['p', 'q', 'r']);

      expect(_seen, ['p', 'q', 'r']);
      expect(result, 'n=3');

      await h.caller.close();
      await h.responder.close();
    });

    test('unary still works', () async {
      final h = _build(starts: 1);

      final res = await h.caller.unaryRequest<RpcString, RpcString>(
        serviceName: 'Svc',
        methodName: 'once',
        request: 'x'.rpc,
        requestCodec: _codec,
        responseCodec: _codec,
      );

      expect(res.value, 'ok');
      expect(_unaryCalls, 1);

      await h.caller.close();
      await h.responder.close();
    });
  });
}
