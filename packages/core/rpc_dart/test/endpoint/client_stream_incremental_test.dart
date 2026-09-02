// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// A client-streaming handler must consume messages AS THEY ARRIVE -- that is
// the whole point of the shape, and what an upload writing chunks to storage
// depends on. Every shape starts its responder on the first request frame
// except client-stream, which was excluded in _handleDataMessage: the only
// thing that started the handler was the peer's half-close.
//
// Measured with five chunks sent 120ms apart:
//
//     0ms client sends chunk 1
//   122ms client sends chunk 2
//   ...
//   490ms client sends chunk 5
//   692ms client half-closes
//   698ms HANDLER STARTED          <-- nothing ran until here
//   702ms handler got chunk c1 .. c5
//
// The same cause is an unauthenticated memory exhaustion: the messages pile up
// in `_clientBufferedMessages`, a plain List with no bound. maxMessageSize
// bounds one frame and maxActiveStreams bounds the stream count, but nothing
// bounds how much a single stream accumulates. A peer that opens one
// client-stream and never half-closes, against a handler that consumes and
// discards:
//
//   before: handler consumed    0 of 8000 chunks, RSS +494 MB (500 MiB sent)
//   after:  handler consumed 8000 of 8000 chunks, RSS +4 MB
//
// Fixed by dispatching client-stream on the first payload like every other
// shape. _ensureResponder is idempotent, so the half-close still starts a call
// that carried no messages at all.
//
// The bound responder is then fed by the pipeline (_pipelineFedRequestStream)
// rather than by transport.getMessagesForStream. The other shapes bind while
// handling the stream's FIRST frame, so the per-stream view carries everything
// they still need; a client-stream responder consumes for the whole call, and
// the default getMessagesForStream is a plain `where` over a non-replaying
// broadcast -- it drops whatever the transport dispatched before the
// subscription existed. RpcChannelTransport overrides it with per-stream
// buffering, but a transport is a public extension point, and the pipeline sees
// every frame anyway. rpc_responder_premethod_reorder_test, whose fake
// transport does not override it, is the regression guard for that.

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

/// Completed by the handler as each named chunk arrives.
Map<String, Completer<void>> _arrivals = {};
Completer<void> _arrival(String key) =>
    _arrivals.putIfAbsent(key, () => Completer<void>());

/// Every value the handlers observed, in arrival order.
List<String> _seen = [];

/// Held so a handler can be kept from returning.
Completer<void> _hold = Completer<void>();

/// A plain object for the zero-copy registrations.
final class Chunk {
  const Chunk(this.v);
  final String v;
}

void _record(String value) {
  _seen.add(value);
  final c = _arrival(value);
  if (!c.isCompleted) c.complete();
}

final class _Contract extends RpcResponderContract {
  _Contract() : super('Svc');

  @override
  void setup() {
    addClientStreamMethod<RpcString, RpcString>(
      methodName: 'collect',
      handler: (reqs, {RpcContext? context}) async {
        await for (final r in reqs) {
          _record(r.value);
        }
        return 'ok:${_seen.length}'.rpc;
      },
      requestCodec: _codec,
      responseCodec: _codec,
    );
    addClientStreamMethod<RpcString, RpcString>(
      methodName: 'fails',
      handler: (reqs, {RpcContext? context}) async {
        await for (final r in reqs) {
          _record(r.value);
          throw RpcStatusException(RpcStatus.notFound, 'gone');
        }
        return 'never'.rpc;
      },
      requestCodec: _codec,
      responseCodec: _codec,
    );
    addClientStreamMethod<RpcString, RpcString>(
      methodName: 'returnsEarly',
      handler: (reqs, {RpcContext? context}) async {
        // Deliberately does NOT drain: only reachable now that the handler
        // starts while the peer is still sending.
        return 'early'.rpc;
      },
      requestCodec: _codec,
      responseCodec: _codec,
    );
    addClientStreamMethod<RpcString, RpcString>(
      methodName: 'slow',
      handler: (reqs, {RpcContext? context}) async {
        await for (final r in reqs) {
          _record(r.value);
          await _hold.future;
        }
        return 'ok:${_seen.length}'.rpc;
      },
      requestCodec: _codec,
      responseCodec: _codec,
    );
    // No codecs -> zero-copy.
    addClientStreamMethod<Chunk, Chunk>(
      methodName: 'collectDirect',
      handler: (reqs, {RpcContext? context}) async {
        await for (final r in reqs) {
          _record(r.v);
        }
        return Chunk('ok:${_seen.length}');
      },
    );
  }
}

typedef _Rig = ({
  IRpcTransport client,
  IRpcTransport server,
  RpcCallerEndpoint caller,
  RpcResponderEndpoint responder,
});

_Rig _connect({bool zeroCopy = false}) {
  final (client, server) = zeroCopy
      ? RpcInMemoryTransport.pair()
      : RpcChannelTransport.pair();
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

/// Waits for the handler to acknowledge [key], failing loudly if it never does.
Future<void> _awaitArrival(String key) => _arrival(key).future.timeout(
  const Duration(seconds: 5),
  onTimeout: () => fail(
    'the handler never received "$key" while the client was still sending: '
    'a client-streaming handler is not being fed incrementally',
  ),
);

void main() {
  setUp(() {
    _arrivals = {};
    _seen = [];
    _hold = Completer<void>();
  });
  tearDown(() {
    if (!_hold.isCompleted) _hold.complete();
  });

  group('a client-streaming handler consumes as messages arrive', () {
    test(
      'each chunk reaches the handler before the next one is sent',
      () async {
        final rig = _connect();
        final requests = StreamController<RpcString>();
        final call = rig.caller.clientStream<RpcString, RpcString>(
          serviceName: 'Svc',
          methodName: 'collect',
          requestCodec: _codec,
          responseCodec: _codec,
        )(requests.stream);

        for (var i = 1; i <= 4; i++) {
          requests.add('c$i'.rpc);
          // The client does not proceed until the server acknowledges, so this
          // cannot pass by accident on a fast machine.
          await _awaitArrival('c$i');
          expect(_seen, [
            for (var j = 1; j <= i; j++) 'c$j',
          ], reason: 'the handler should be exactly $i chunks in');
        }

        await requests.close();
        expect((await call.timeout(const Duration(seconds: 5))).value, 'ok:4');
        await _teardown(rig);
      },
    );

    test('zero-copy delivers incrementally too', () async {
      final rig = _connect(zeroCopy: true);
      final requests = StreamController<Chunk>();
      final call = rig.caller.clientStream<Chunk, Chunk>(
        serviceName: 'Svc',
        methodName: 'collectDirect',
      )(requests.stream);

      for (var i = 1; i <= 4; i++) {
        requests.add(Chunk('z$i'));
        await _awaitArrival('z$i');
      }

      await requests.close();
      expect((await call.timeout(const Duration(seconds: 5))).v, 'ok:4');
      await _teardown(rig);
    });

    test(
      'a peer that never half-closes does not pile up on the server',
      () async {
        // The memory-exhaustion witness, expressed as progress: pre-fix the
        // handler had consumed 0 of these because nothing had started it.
        final rig = _connect();
        final requests = StreamController<RpcString>();
        unawaited(
          rig.caller
              .clientStream<RpcString, RpcString>(
                serviceName: 'Svc',
                methodName: 'collect',
                requestCodec: _codec,
                responseCodec: _codec,
              )(requests.stream)
              .catchError((Object _) => ''.rpc),
        );

        for (var i = 0; i < 200; i++) {
          requests.add('n$i'.rpc);
        }

        await _awaitArrival('n199');
        expect(
          _seen,
          hasLength(200),
          reason:
              'every message should already be consumed, with no half-close',
        );

        await requests.close();
        await _teardown(rig);
      },
    );
  });

  group('unchanged behaviour', () {
    test('a call carrying zero messages still completes', () async {
      // The half-close is the only thing that starts this one, and
      // _stateBoundStream has to synthesise the end-of-stream for it.
      final rig = _connect();
      final empty = StreamController<RpcString>();
      final call = rig.caller.clientStream<RpcString, RpcString>(
        serviceName: 'Svc',
        methodName: 'collect',
        requestCodec: _codec,
        responseCodec: _codec,
      )(empty.stream);
      await empty.close();

      expect((await call.timeout(const Duration(seconds: 5))).value, 'ok:0');
      await _teardown(rig);
    });

    test('every message arrives exactly once, in order', () async {
      // Binding early adds a second delivery route (the buffer and the live
      // subscription); neither may double up or drop.
      final rig = _connect();
      final requests = StreamController<RpcString>();
      final call = rig.caller.clientStream<RpcString, RpcString>(
        serviceName: 'Svc',
        methodName: 'collect',
        requestCodec: _codec,
        responseCodec: _codec,
      )(requests.stream);

      final sent = [for (var i = 0; i < 50; i++) 'm$i'];
      for (final m in sent) {
        requests.add(m.rpc);
      }
      await requests.close();

      expect((await call.timeout(const Duration(seconds: 5))).value, 'ok:50');
      expect(_seen, sent);
      await _teardown(rig);
    });

    test(
      'the response is not delivered before the client half-closes',
      () async {
        final rig = _connect();
        final requests = StreamController<RpcString>();
        var completed = false;
        final call = rig.caller.clientStream<RpcString, RpcString>(
          serviceName: 'Svc',
          methodName: 'collect',
          requestCodec: _codec,
          responseCodec: _codec,
        )(requests.stream);
        unawaited(
          call.then<void>((_) => completed = true).catchError((Object _) {}),
        );

        requests.add('a'.rpc);
        await _awaitArrival('a');
        await Future<void>.delayed(const Duration(milliseconds: 200));
        expect(
          completed,
          isFalse,
          reason: 'the handler must still be waiting for more requests',
        );

        await requests.close();
        expect((await call.timeout(const Duration(seconds: 5))).value, 'ok:1');
        await _teardown(rig);
      },
    );

    test('a handler error still propagates with its own status', () async {
      final rig = _connect();
      final requests = StreamController<RpcString>();
      final call = rig.caller.clientStream<RpcString, RpcString>(
        serviceName: 'Svc',
        methodName: 'fails',
        requestCodec: _codec,
        responseCodec: _codec,
      )(requests.stream);
      requests.add('boom'.rpc);
      unawaited(requests.close());

      await expectLater(
        call.timeout(const Duration(seconds: 5)),
        throwsA(
          isA<RpcStatusException>().having(
            (e) => e.statusCode,
            'statusCode',
            RpcStatus.notFound,
          ),
        ),
      );
      await _teardown(rig);
    });

    test('a handler that returns without draining still answers', () async {
      // Newly reachable: the handler can now finish while the peer is mid-send.
      final rig = _connect();
      final requests = StreamController<RpcString>();
      final call = rig.caller.clientStream<RpcString, RpcString>(
        serviceName: 'Svc',
        methodName: 'returnsEarly',
        requestCodec: _codec,
        responseCodec: _codec,
      )(requests.stream);
      for (var i = 0; i < 10; i++) {
        requests.add('x$i'.rpc);
      }
      await requests.close();

      expect((await call.timeout(const Duration(seconds: 5))).value, 'early');
      await _teardown(rig);
    });

    test('a slow handler still receives everything the peer sent', () async {
      // Backpressure path: the handler blocks between messages, so the frames
      // queue behind it rather than being dropped.
      final rig = _connect();
      final requests = StreamController<RpcString>();
      final call = rig.caller.clientStream<RpcString, RpcString>(
        serviceName: 'Svc',
        methodName: 'slow',
        requestCodec: _codec,
        responseCodec: _codec,
      )(requests.stream);

      for (var i = 0; i < 20; i++) {
        requests.add('s$i'.rpc);
      }
      await requests.close();
      await _awaitArrival('s0');
      _hold.complete();

      expect((await call.timeout(const Duration(seconds: 5))).value, 'ok:20');
      expect(_seen, [for (var i = 0; i < 20; i++) 's$i']);
      await _teardown(rig);
    });

    test('repeated calls leave no per-call state behind', () async {
      final rig = _connect();
      for (var i = 0; i < 15; i++) {
        final requests = StreamController<RpcString>();
        final call = rig.caller.clientStream<RpcString, RpcString>(
          serviceName: 'Svc',
          methodName: 'collect',
          requestCodec: _codec,
          responseCodec: _codec,
        )(requests.stream);
        requests
          ..add('a'.rpc)
          ..add('b'.rpc);
        await requests.close();
        await call.timeout(const Duration(seconds: 5));
      }
      await Future<void>.delayed(const Duration(milliseconds: 300));

      expect(rig.caller.collectEndpointMetrics()['pendingRequests'], 0);
      expect(rig.responder.collectEndpointMetrics()['openStreams'], 0);
      await _teardown(rig);
    });
  });
}
