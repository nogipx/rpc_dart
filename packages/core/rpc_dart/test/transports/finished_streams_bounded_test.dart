// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// RpcChannelTransport._finishedStreams exists to keep finishSending()
// idempotent, and releaseStreamId() prunes it at teardown. But teardown can
// happen BEFORE the terminal frame is sent, and then nothing removes the entry
// again.
//
// A handler that outlives its deadline does exactly that. Instrumenting both
// sides of the set with a 4s handler against a 40ms client deadline:
//
//   normal call : ADD 1     then REMOVE 1                   -> net empty
//   aborted call: REMOVE 5  (at the 2s reclaim grace)
//                 ADD 5     (at 4s, when the handler answers) -> retained
//
// One int retained per aborted call, for the life of the connection, with the
// peer choosing the deadline. Measured over 3000 deadline-aborted calls:
//
//   before: finishedStreams grew 1032 -> 1528 -> 2049 -> 2996, still climbing
//   after : 1024 -> 1024 -> 1024, flat at the cap
//
// Nothing distinguishes the two orderings at the moment of the add -- the
// stream is absent from _activeStreams and _streamControllers either way -- so
// the set is bounded rather than pruned.
//
// The marker itself is load-bearing and was NOT removed: measured across the
// core suite it suppresses a genuine duplicate end-of-stream 4 times, and a
// second one is a protocol violation on a transport with real stream state.

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

/// Matches `_maxRememberedFinishedStreams` in RpcChannelTransport.
const _cap = 1024;

final class _Svc extends RpcResponderContract {
  _Svc() : super('Svc');

  @override
  void setup() {
    // Still running when the responder's reclaim grace fires, so its trailer
    // lands after teardown -- the ordering that leaks.
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'slow',
      handler: (r, {RpcContext? context}) async {
        await Future<void>.delayed(const Duration(milliseconds: 2500));
        return 'late'.rpc;
      },
      requestCodec: _codec,
      responseCodec: _codec,
    );

    addUnaryMethod<RpcString, RpcString>(
      methodName: 'fast',
      handler: (r, {RpcContext? context}) async => 'ok'.rpc,
      requestCodec: _codec,
      responseCodec: _codec,
    );

    addClientStreamMethod<RpcString, RpcString>(
      methodName: 'cs',
      handler: (requests, {RpcContext? context}) async {
        var n = 0;
        await for (final _ in requests) {
          n++;
        }
        return 'c$n'.rpc;
      },
      requestCodec: _codec,
      responseCodec: _codec,
    );
  }
}

typedef _Harness = ({
  IRpcTransport client,
  IRpcTransport server,
  RpcCallerEndpoint caller,
  RpcResponderEndpoint responder,
});

_Harness _build() {
  final (client, server) = RpcChannelTransport.pair();
  final caller = RpcCallerEndpoint(transport: client);
  final responder = RpcResponderEndpoint(transport: server);
  responder.registerServiceContract(_Svc());
  responder.start();
  return (client: client, server: server, caller: caller, responder: responder);
}

Future<int> _finished(IRpcTransport t) async {
  final d = (await t.health()).details;
  final v = d['finishedStreams'];
  return v is int ? v : -1;
}

Future<void> _abortedCall(RpcCallerEndpoint caller) async {
  try {
    await caller.unaryRequest<RpcString, RpcString>(
      serviceName: 'Svc',
      methodName: 'slow',
      request: 'x'.rpc,
      requestCodec: _codec,
      responseCodec: _codec,
      context: RpcContext.withTimeout(const Duration(milliseconds: 2)),
    );
  } catch (_) {
    // The deadline is the point.
  }
}

void main() {
  group('finishedStreams under deadline-aborted calls', () {
    // WITNESS: without the cap this reached 2996 and kept climbing.
    test(
      'stays bounded across many aborted calls',
      () async {
        final h = _build();

        for (var i = 0; i < 2500; i++) {
          await _abortedCall(h.caller);
        }
        // Let every late trailer land and re-add its id.
        await Future<void>.delayed(const Duration(seconds: 4));

        final n = await _finished(h.server);
        expect(
          n,
          lessThanOrEqualTo(_cap),
          reason:
              'finishedStreams reached $n after 2500 aborted calls; it retains '
              'one id per call and nothing prunes it again',
        );

        await h.caller.close();
        await h.responder.close();
      },
      timeout: const Timeout(Duration(minutes: 3)),
    );
  });

  group('the surrounding behaviour is unchanged', () {
    // GUARD: an ordinary call must still return the set to its baseline --
    // capping must not be mistaken for "leaking a little on every call".
    test('a normal call leaves nothing behind', () async {
      final h = _build();

      for (var i = 0; i < 20; i++) {
        await h.caller.unaryRequest<RpcString, RpcString>(
          serviceName: 'Svc',
          methodName: 'fast',
          request: 'x'.rpc,
          requestCodec: _codec,
          responseCodec: _codec,
        );
      }
      await Future<void>.delayed(const Duration(milliseconds: 300));

      expect(
        await _finished(h.server),
        0,
        reason: 'a completed call should prune its own entry',
      );

      await h.caller.close();
      await h.responder.close();
    });

    // GUARD: finishSending() idempotency is what the set is FOR. A client
    // stream half-closes explicitly, so this exercises the marker's real job.
    test('a client stream still completes exactly once', () async {
      final h = _build();

      for (var i = 0; i < 5; i++) {
        final call = h.caller.clientStream<RpcString, RpcString>(
          serviceName: 'Svc',
          methodName: 'cs',
          requestCodec: _codec,
          responseCodec: _codec,
        );
        final res = await call(Stream.fromIterable(['a'.rpc, 'b'.rpc]));
        expect(res.value, 'c2');
      }
      await Future<void>.delayed(const Duration(milliseconds: 300));

      expect(await _finished(h.server), 0);

      await h.caller.close();
      await h.responder.close();
    });
  });
}
