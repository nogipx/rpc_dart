// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// _buildBidirectionalStream.cleanup() tore the call down with
//
//   await response?.cancel();
//   await request?.cancel();
//   await caller.close();
//   if (!controller.isClosed) await controller.close();
//
// The consumer-cancelled branch above it already documented why awaiting
// request.cancel() is unsafe: `requests` is a suspended async* middleware
// chain, and cancelling a generator parked in `await for` does not complete
// until its upstream produces again -- which, for a request stream the caller
// keeps open, is never.
//
// That reasoning was applied only to the cancel path. It holds just as well
// when the SERVER finishes first, and there the await never returned, leaving
// controller.close() unreachable:
//
//   bidi, server yields once then completes:
//     client keeps requests open -> HUNG -- stream never closed (responses=1)
//     client closes requests     -> stream closed cleanly (responses=1)
//
// So a bidirectional call whose server ends the conversation while the client
// still holds its request sink open -- an ordinary shape: a final message, an
// error, a subscription that naturally terminates -- delivered every response
// and then hung forever.

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

final class _Contract extends RpcResponderContract {
  _Contract() : super('Svc');

  @override
  void setup() {
    // Ends after one response, without waiting for the client to close.
    addBidirectionalMethod<RpcString, RpcString>(
      methodName: 'serverEndsFirst',
      handler: (requests, {RpcContext? context}) async* {
        yield 'one'.rpc;
      },
      requestCodec: _codec,
      responseCodec: _codec,
    );

    // Ends by throwing, the other way a server ends a conversation early.
    addBidirectionalMethod<RpcString, RpcString>(
      methodName: 'serverThrows',
      handler: (requests, {RpcContext? context}) async* {
        yield 'partial'.rpc;
        throw RpcStatusException(RpcStatus.failedPrecondition, 'done here');
      },
      requestCodec: _codec,
      responseCodec: _codec,
    );

    // Never stops emitting; the shape whose cancel works today.
    addBidirectionalMethod<RpcString, RpcString>(
      methodName: 'chatty',
      handler: (requests, {RpcContext? context}) async* {
        while (true) {
          yield 'v'.rpc;
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
      },
      requestCodec: _codec,
      responseCodec: _codec,
    );

    // Mirrors until the client closes, the shape that already worked.
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

Future<void> _teardown(_Rig r) async {
  await r.caller.close();
  await r.responder.close();
  await r.client.close();
  await r.server.close();
}

void main() {
  test('the stream ends when the server finishes first', () async {
    final rig = _connect();
    // Deliberately left OPEN for the whole call -- the condition that hung.
    final requests = StreamController<RpcString>();
    requests.add('a'.rpc);

    final got = <String>[];
    await rig.caller
        .bidirectionalStream<RpcString, RpcString>(
          serviceName: 'Svc',
          methodName: 'serverEndsFirst',
          requests: requests.stream,
          requestCodec: _codec,
          responseCodec: _codec,
        )
        .forEach((r) => got.add(r.value))
        .timeout(
          const Duration(seconds: 5),
          onTimeout: () => fail(
            'the response stream never closed after the server finished',
          ),
        );

    expect(got, ['one']);
    await requests.close();
    await _teardown(rig);
  });

  test('a server error terminates the stream too', () async {
    final rig = _connect();
    final requests = StreamController<RpcString>();
    requests.add('a'.rpc);

    await expectLater(
      rig.caller
          .bidirectionalStream<RpcString, RpcString>(
            serviceName: 'Svc',
            methodName: 'serverThrows',
            requests: requests.stream,
            requestCodec: _codec,
            responseCodec: _codec,
          )
          .toList()
          .timeout(
            const Duration(seconds: 5),
            onTimeout: () =>
                fail('the stream never ended after a server error'),
          ),
      throwsA(isA<RpcStatusException>()),
    );

    await requests.close();
    await _teardown(rig);
  });

  test('the client-closes-first shape still works', () async {
    // This path always worked; it must keep working.
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
    await _teardown(rig);
  });

  test('cancelling an actively-producing stream still returns promptly', () {
    // Guard, not a bug witness: this shape works today and must keep working.
    //
    // NOTE the narrowness. cancel() only returns while the response stream is
    // PRODUCING. Measured with the request stream left open:
    //
    //   infinite handler, 1 request sent -> cancel returned (received=19)
    //   infinite handler, no request     -> CANCEL DEADLOCKED (received=0)
    //   mirror handler,   1 request sent -> CANCEL DEADLOCKED (received=1)
    //
    // That is a SEPARATE, pre-existing deadlock: bidirectionalStream returns
    // the handleBidirectionalStream async* chain directly, and cancelling a
    // generator parked in `await for` does not complete until its upstream
    // produces again. serverStream in the same file already bridges through an
    // explicit StreamController with onCancel for exactly this reason; the
    // bidirectional path never got that treatment. Not fixed here.
    return _cancelWhileProducing();
  });
}

/// Cancels a bidi subscription against a handler that never stops emitting.
Future<void> _cancelWhileProducing() async {
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
  expect(received, greaterThan(0), reason: 'handler should be producing');

  await sub.cancel().timeout(
    const Duration(seconds: 5),
    onTimeout: () => fail('bidirectional cancel() deadlocked'),
  );

  await requests.close();
  await _teardown(rig);
}
