// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// A bidirectional RPC may legitimately send zero client messages: the client
// opens the call and listens, and the server pushes. That is the natural shape
// of a subscription.
//
// _handleEndOfStream rejected it. The guard
//
//   if (state.responder == null && state.lastPayloadMessage == null) {
//     ... INVALID_ARGUMENT 'Request stream closed without payload' ...
//   }
//
// is correct for unary and server-stream, which require exactly one request
// message, and it caught bidirectional in the same net. Only clientStream was
// excluded.
//
// Routing bidi to _ensureResponder exposed a second half: the responder is then
// created AT end-of-stream, so its transport subscription starts after that
// frame and never sees it. The handler's `await for (requests)` would wait
// forever on a client that had already finished. The stream state now records
// the half-close and the bound stream replays it.

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

/// Traces handler lifecycle, so "ran" and "ran to completion" are separable.
final List<String> _trace = [];

final class _Contract extends RpcResponderContract {
  _Contract() : super('Svc');

  @override
  void setup() {
    // Pushes first, then echoes: works with or without client input.
    addBidirectionalMethod<RpcString, RpcString>(
      methodName: 'greet',
      handler: (requests, {RpcContext? context}) async* {
        _trace.add('start');
        yield 'hello'.rpc;
        await for (final r in requests) {
          yield r;
        }
        _trace.add('end');
      },
      requestCodec: _codec,
      responseCodec: _codec,
    );

    // Requires exactly one request message -- must still be rejected when the
    // client closes without sending.
    addServerStreamMethod<RpcString, RpcString>(
      methodName: 'expand',
      handler: (request, {RpcContext? context}) async* {
        _trace.add('expand');
        yield request;
      },
      requestCodec: _codec,
      responseCodec: _codec,
    );

    addUnaryMethod<RpcString, RpcString>(
      methodName: 'echo',
      handler: (request, {RpcContext? context}) async {
        _trace.add('echo');
        return request;
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

Stream<RpcString> _requests(List<String> values) {
  final c = StreamController<RpcString>();
  for (final v in values) {
    c.add(v.rpc);
  }
  unawaited(c.close());
  return c.stream;
}

Future<List<String>> _bidi(_Rig rig, List<String> send) {
  return rig.caller
      .bidirectionalStream<RpcString, RpcString>(
        serviceName: 'Svc',
        methodName: 'greet',
        requests: _requests(send),
        requestCodec: _codec,
        responseCodec: _codec,
      )
      .map((r) => r.value)
      .toList()
      .timeout(
        const Duration(seconds: 5),
        onTimeout: () =>
            fail('the bidi call never completed (sent ${send.length})'),
      );
}

/// Opens [method] at the transport level and half-closes without a payload,
/// asserting the responder answers INVALID_ARGUMENT.
Future<void> _expectRefused(String method) async {
  final rig = _connect();

  final streamId = rig.client.createStream();
  final trailer = Completer<RpcMetadata>();
  final sub = rig.client.getMessagesForStream(streamId).listen((m) {
    final meta = m.metadata;
    if (meta == null) return;
    if (meta.getHeaderValue(RpcHeaders.grpcStatus) == null) return;
    if (!trailer.isCompleted) trailer.complete(meta);
  }, onError: (Object _) {});

  await rig.client.sendMetadata(
    streamId,
    RpcMetadata.forClientRequest('Svc', method),
  );
  await rig.client.finishSending(streamId);

  final meta = await trailer.future.timeout(
    const Duration(seconds: 5),
    onTimeout: () => fail('$method was never refused'),
  );

  expect(
    meta.getHeaderValue(RpcHeaders.grpcStatus),
    RpcStatus.invalidArgument.toString(),
    reason: '$method must still reject a call with no request message',
  );
  expect(_trace, isEmpty, reason: 'the handler must not have run');

  await sub.cancel();
  await _teardown(rig);
}

void main() {
  setUp(_trace.clear);

  test('a bidi call that sends nothing still runs', () async {
    final rig = _connect();

    expect(await _bidi(rig, []), ['hello']);
    expect(_trace, [
      'start',
      'end',
    ], reason: 'the handler must run AND see its request stream close');

    await _teardown(rig);
  });

  group('sending is unaffected', () {
    test('one message', () async {
      final rig = _connect();
      expect(await _bidi(rig, ['x']), ['hello', 'x']);
      expect(_trace, ['start', 'end']);
      await _teardown(rig);
    });

    test('several messages, in order', () async {
      final rig = _connect();
      expect(await _bidi(rig, ['a', 'b', 'c']), ['hello', 'a', 'b', 'c']);
      expect(_trace, ['start', 'end']);
      await _teardown(rig);
    });
  });

  group('shapes that require a request are still rejected', () {
    test('server-stream closed without a payload', () async {
      final rig = _connect();

      await expectLater(
        rig.caller
            .serverStream<RpcString, RpcString>(
              serviceName: 'Svc',
              methodName: 'expand',
              request: 'x'.rpc,
              requestCodec: _codec,
              responseCodec: _codec,
            )
            .toList(),
        completion(isNotEmpty),
      );
      expect(_trace, ['expand'], reason: 'the normal path must still work');

      await _teardown(rig);
    });

    test('server-stream opened and closed with no payload is refused', () {
      // The guard was NARROWED, not deleted. The caller API always sends a
      // request for these shapes, so drive the transport directly: open the
      // stream with headers, then half-close without a payload.
      return _expectRefused('expand');
    });

    test('unary opened and closed with no payload is refused', () {
      return _expectRefused('echo');
    });
  });

  test('an idle bidi call is still cancellable', () async {
    // The empty-request shape is exactly the one that used to deadlock cancel;
    // both fixes have to hold together.
    final rig = _connect();
    final requests = StreamController<RpcString>();
    unawaited(requests.close());

    final sub = rig.caller
        .bidirectionalStream<RpcString, RpcString>(
          serviceName: 'Svc',
          methodName: 'greet',
          requests: requests.stream,
          requestCodec: _codec,
          responseCodec: _codec,
        )
        .listen((_) {}, onError: (Object _) {});

    await Future<void>.delayed(const Duration(milliseconds: 150));
    await sub.cancel().timeout(
      const Duration(seconds: 5),
      onTimeout: () => fail('cancel() deadlocked on an empty bidi call'),
    );

    await _teardown(rig);
  });
}
