// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// bidirectionalStream() returned the async* chain
// (handleBidirectionalStream -> middleware -> _buildBidirectionalStream)
// directly. Cancelling a subscription to a chain of suspended `async*`/
// `await for` generators does not complete until the upstream produces again,
// so sub.cancel() only returned while the server happened to be emitting.
//
// serverStream() in the same file has bridged through an explicit
// StreamController for exactly this reason since the dart2js hang. The
// bidirectional path never got that treatment, and had the same defect on the
// VM too. Measured with the request stream left open:
//
//   infinite, 1 request  -> cancel returned (received=19)
//   infinite, no request -> CANCEL DEADLOCKED
//   mirror,   1 request  -> CANCEL DEADLOCKED (received=1)
//   mirror,   no request -> CANCEL DEADLOCKED
//
// An IDLE bidi stream -- a subscription waiting for the next server push,
// which is the normal state of one -- could not be cancelled at all. The one
// case that worked, and the only one the existing suite covered, was a handler
// emitting continuously.
//
// After the bridge, every shape cancels in 0-3ms.

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

/// Counts iterations of the never-ending handlers, to prove they stop.
int _ticks = 0;

final class _Contract extends RpcResponderContract {
  _Contract() : super('Svc');

  @override
  void setup() {
    // Echoes, then parks awaiting more input: idle between client messages.
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

    // Never emits at all.
    addBidirectionalMethod<RpcString, RpcString>(
      methodName: 'silent',
      handler: (requests, {RpcContext? context}) async* {
        await Completer<void>().future;
      },
      requestCodec: _codec,
      responseCodec: _codec,
    );

    // Emits continuously: the one shape whose cancel already worked.
    addBidirectionalMethod<RpcString, RpcString>(
      methodName: 'chatty',
      handler: (requests, {RpcContext? context}) async* {
        while (true) {
          _ticks++;
          yield 'v'.rpc;
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
      },
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

Future<void> _teardown(_Rig r, StreamController<RpcString> requests) async {
  if (!requests.isClosed) await requests.close();
  await r.caller.close();
  await r.responder.close();
  await r.client.close();
  await r.server.close();
}

/// Cancels a subscription to [method], failing if cancel() does not return.
Future<void> _expectCancelReturns(
  String method, {
  required bool sendRequest,
}) async {
  final rig = _connect();
  final requests = StreamController<RpcString>();
  if (sendRequest) requests.add('a'.rpc);

  final sub = rig.caller
      .bidirectionalStream<RpcString, RpcString>(
        serviceName: 'Svc',
        methodName: method,
        requests: requests.stream,
        requestCodec: _codec,
        responseCodec: _codec,
      )
      .listen((_) {}, onError: (Object _) {});

  await Future<void>.delayed(const Duration(milliseconds: 150));

  await sub.cancel().timeout(
    const Duration(seconds: 5),
    onTimeout: () => fail(
      "cancel() deadlocked on an idle '$method' stream "
      '(sendRequest: $sendRequest)',
    ),
  );

  await _teardown(rig, requests);
}

void main() {
  setUp(() => _ticks = 0);

  group('an idle bidi stream can be cancelled', () {
    test('handler parked awaiting input, after one echo', () {
      return _expectCancelReturns('mirror', sendRequest: true);
    });

    test('handler parked awaiting input, nothing sent', () {
      return _expectCancelReturns('mirror', sendRequest: false);
    });

    test('handler that never emits', () {
      return _expectCancelReturns('silent', sendRequest: true);
    });

    test('handler emitting continuously (already worked)', () {
      return _expectCancelReturns('chatty', sendRequest: true);
    });
  });

  test('cancelling still stops the server handler', () async {
    // The guard that matters: a bridge that returns from cancel() without
    // propagating it would pass every test above while leaving the server
    // producing forever.
    final rig = _connect();
    final requests = StreamController<RpcString>();
    requests.add('a'.rpc);

    var received = 0;
    final sub = rig.caller
        .bidirectionalStream<RpcString, RpcString>(
          serviceName: 'Svc',
          methodName: 'chatty',
          requests: requests.stream,
          requestCodec: _codec,
          responseCodec: _codec,
        )
        .listen((_) => received++, onError: (Object _) {});

    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(received, greaterThan(0));

    await sub.cancel().timeout(const Duration(seconds: 5));

    // An async* generator resumes once past its suspension point before
    // terminating, so allow a wind-down before sampling.
    await Future<void>.delayed(const Duration(milliseconds: 300));
    final settled = _ticks;
    await Future<void>.delayed(const Duration(milliseconds: 500));

    expect(
      _ticks,
      settled,
      reason:
          'the server handler kept producing after cancellation '
          '(was $settled, now $_ticks)',
    );

    await _teardown(rig, requests);
  });

  test('normal completion is unaffected', () async {
    // The bridge must not swallow the ordinary path.
    final rig = _connect();
    final requests = StreamController<RpcString>();
    requests.add('a'.rpc);
    requests.add('b'.rpc);
    unawaited(requests.close());

    final got = await rig.caller
        .bidirectionalStream<RpcString, RpcString>(
          serviceName: 'Svc',
          methodName: 'mirror',
          requests: requests.stream,
          requestCodec: _codec,
          responseCodec: _codec,
        )
        .map((r) => r.value)
        .toList()
        .timeout(const Duration(seconds: 5));

    expect(got, ['a', 'b']);
    await _teardown(rig, requests);
  });

  test('an unlistened bidi stream still tracks nothing', () async {
    // Tracking moved from the interceptor handler into the bridge's onListen;
    // both are "on first listen", and a cold stream must still track nothing.
    final rig = _connect();
    for (var i = 0; i < 10; i++) {
      rig.caller.bidirectionalStream<RpcString, RpcString>(
        serviceName: 'Svc',
        methodName: 'mirror',
        requests: const Stream<RpcString>.empty(),
        requestCodec: _codec,
        responseCodec: _codec,
      );
    }
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(rig.caller.collectEndpointMetrics()['pendingRequests'], 0);

    await rig.caller.close();
    await rig.responder.close();
    await rig.client.close();
    await rig.server.close();
  });
}
