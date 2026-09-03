// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// A request stream that ERRORS tore the call down locally and told the server
// nothing. Its handler stayed parked in `await for (requests)` forever, holding
// a responder-state entry and (for bidi) a transport stream controller.
//
// The healthy path half-closes via finishSending(), so the handler ends on its
// own; the cancellation-token notice only covered consumer cancellation. An
// errored request stream fell between the two.
//
// Measured over ONE connection, 50 calls whose request stream throws:
//
//   clientStream   : activeResponders=51 metadataStreams=51
//   bidirectional  : activeResponders=51 metadataStreams=51
//                    transport streamControllers 1 -> 51
//
// `activeStreams` stayed 0 the whole time, so maxActiveStreams never noticed --
// the growth is unbounded and invisible to the limit meant to bound it.
//
// Instrumenting every hop at once is what located it. The same calls aborted
// through an explicit token.cancel() left NOTHING behind (parked: 0), which
// ruled out the responder's handling of a notice and pinned it to the caller
// never sending one:
//
//   BIDI,          request stream errors: token fired 10/10, handler exited 0/10
//   CLIENT STREAM, request stream errors: token fired  0/10, handler exited 0/10
//   BIDI,          explicit token.cancel(): handler exited 10/10
//   CLIENT STREAM, explicit token.cancel(): handler exited 10/10

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

int _bdEntered = 0, _bdExited = 0, _csEntered = 0, _csExited = 0;

final class _Svc extends RpcResponderContract {
  _Svc() : super('Svc');

  @override
  void setup() {
    addBidirectionalMethod<RpcString, RpcString>(
      methodName: 'bd',
      handler: (requests, {RpcContext? context}) async* {
        _bdEntered++;
        try {
          await for (final r in requests) {
            yield r;
          }
        } finally {
          _bdExited++;
        }
      },
      requestCodec: _codec,
      responseCodec: _codec,
    );
    addClientStreamMethod<RpcString, RpcString>(
      methodName: 'cs',
      handler: (requests, {RpcContext? context}) async {
        _csEntered++;
        try {
          var n = 0;
          await for (final _ in requests) {
            n++;
          }
          return 'got$n'.rpc;
        } finally {
          _csExited++;
        }
      },
      requestCodec: _codec,
      responseCodec: _codec,
    );
  }
}

typedef _Harness = ({
  RpcCallerEndpoint caller,
  RpcResponderEndpoint responder,
  IRpcTransport serverTransport,
});

_Harness _build() {
  final (client, server) = RpcChannelTransport.pair();
  final caller = RpcCallerEndpoint(transport: client);
  final responder = RpcResponderEndpoint(transport: server);
  responder.registerServiceContract(_Svc());
  responder.start();
  return (caller: caller, responder: responder, serverTransport: server);
}

/// A request stream that produces once and then fails, the way a real producer
/// does when the thing feeding it breaks partway through.
Stream<RpcString> _failingRequests() async* {
  yield 'a'.rpc;
  await Future<void>.delayed(const Duration(milliseconds: 5));
  throw StateError('producer exploded');
}

/// Polls rather than sleeping a fixed time: the assertion is "the handler
/// eventually stops", and how fast that happens is not what is under test.
Future<bool> _reaches(bool Function() condition) async {
  for (var i = 0; i < 200; i++) {
    if (condition()) return true;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  return false;
}

Future<Map<String, Object?>> _responderState(RpcResponderEndpoint r) async =>
    (await r.health()).endpointStatus.details;

void main() {
  setUp(() {
    _bdEntered = 0;
    _bdExited = 0;
    _csEntered = 0;
    _csExited = 0;
  });

  group('a request stream that errors', () {
    // WITNESS
    test('does not park a bidirectional handler', () async {
      final h = _build();
      const n = 5;

      for (var i = 0; i < n; i++) {
        try {
          await h.caller
              .bidirectionalStream<RpcString, RpcString>(
                serviceName: 'Svc',
                methodName: 'bd',
                requests: _failingRequests(),
                requestCodec: _codec,
                responseCodec: _codec,
              )
              .toList();
        } catch (_) {
          // The consumer is told; the point of the test is the SERVER.
        }
      }

      expect(
        await _reaches(() => _bdEntered == n),
        isTrue,
        reason: 'the handler never ran',
      );
      final done = await _reaches(() => _bdExited == _bdEntered);
      expect(
        done,
        isTrue,
        reason:
            '${_bdEntered - _bdExited} of $n handlers are still parked in '
            '`await for (requests)`; the server was never told the request '
            'stream failed',
      );

      final state = await _responderState(h.responder);
      expect(state['activeResponders'], 0);
      expect(state['metadataStreams'], 0);

      final transport = (await h.serverTransport.health()).details;
      expect(
        transport['streamControllers'],
        0,
        reason: 'per-stream transport bookkeeping was never reclaimed',
      );

      await h.caller.close();
      await h.responder.close();
    });

    // WITNESS
    test('does not park a client-streaming handler', () async {
      final h = _build();
      const n = 5;

      for (var i = 0; i < n; i++) {
        try {
          final call = h.caller.clientStream<RpcString, RpcString>(
            serviceName: 'Svc',
            methodName: 'cs',
            requestCodec: _codec,
            responseCodec: _codec,
          );
          await call(_failingRequests());
        } catch (_) {}
      }

      expect(
        await _reaches(() => _csEntered == n),
        isTrue,
        reason: 'the handler never ran',
      );
      final done = await _reaches(() => _csExited == _csEntered);
      expect(
        done,
        isTrue,
        reason:
            '${_csEntered - _csExited} of $n handlers are still parked in '
            '`await for (requests)`; the server was never told the request '
            'stream failed',
      );

      final state = await _responderState(h.responder);
      expect(state['activeResponders'], 0);
      expect(state['metadataStreams'], 0);

      await h.caller.close();
      await h.responder.close();
    });

    // WITNESS: the leak is invisible to maxActiveStreams, so accounting has to
    // be against the responder's own state, not the transport's stream count.
    test('leaves no responder state behind across many calls', () async {
      final h = _build();
      const n = 20;

      for (var i = 0; i < n; i++) {
        try {
          await h.caller
              .bidirectionalStream<RpcString, RpcString>(
                serviceName: 'Svc',
                methodName: 'bd',
                requests: _failingRequests(),
                requestCodec: _codec,
                responseCodec: _codec,
              )
              .toList();
        } catch (_) {}
      }

      final settled = await _reaches(() => _bdExited == n);
      expect(settled, isTrue, reason: '${n - _bdExited} handlers still parked');

      final state = await _responderState(h.responder);
      expect(
        state['activeResponders'],
        0,
        reason: 'responder state grows once per call, without bound',
      );

      await h.caller.close();
      await h.responder.close();
    });
  });

  // GUARDS: pass on both sides of the fix. The abort notice must not fire on a
  // call that ended normally, or it would reset a stream that is already done.
  group('the healthy paths are unaffected', () {
    test('a bidirectional call still echoes and completes', () async {
      final h = _build();

      final got = await h.caller
          .bidirectionalStream<RpcString, RpcString>(
            serviceName: 'Svc',
            methodName: 'bd',
            requests: Stream.fromIterable(['a'.rpc, 'b'.rpc]),
            requestCodec: _codec,
            responseCodec: _codec,
          )
          .toList();

      expect(got.map((e) => e.value), ['a', 'b']);
      expect(await _reaches(() => _bdExited == 1), isTrue);
      expect((await _responderState(h.responder))['activeResponders'], 0);

      await h.caller.close();
      await h.responder.close();
    });

    test('a client-streaming call still returns its response', () async {
      final h = _build();

      final call = h.caller.clientStream<RpcString, RpcString>(
        serviceName: 'Svc',
        methodName: 'cs',
        requestCodec: _codec,
        responseCodec: _codec,
      );
      final res = await call(Stream.fromIterable(['a'.rpc, 'b'.rpc]));

      expect(res.value, 'got2');
      expect(await _reaches(() => _csExited == 1), isTrue);
      expect((await _responderState(h.responder))['activeResponders'], 0);

      await h.caller.close();
      await h.responder.close();
    });

    test('an empty request stream still completes normally', () async {
      final h = _build();

      final call = h.caller.clientStream<RpcString, RpcString>(
        serviceName: 'Svc',
        methodName: 'cs',
        requestCodec: _codec,
        responseCodec: _codec,
      );
      final res = await call(const Stream<RpcString>.empty());

      expect(res.value, 'got0');
      expect((await _responderState(h.responder))['activeResponders'], 0);

      await h.caller.close();
      await h.responder.close();
    });
  });
}
