// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// Every inbound message was dispatched twice: routed to its own stream's
// controller AND added to the transport-wide broadcast. The broadcast exists for
// NEW-STREAM ROUTING — it is how the responder pipeline discovers a peer-initiated
// call — so a response on a stream we opened ourselves served nobody there.
//
// It was not free. The broadcast buffers while unlistened, so a caller-only
// endpoint has to subscribe a no-op listener just to drain it
// (`startCallerListening`, whose own doc says so). Where that is missed, the
// buffer retained every response the caller had already consumed — which is what
// the witness below reads, by attaching a late subscriber and counting the replay.
//
// The measurements are in `.claude/loop/rounds/508`.

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

final class _Feed extends RpcResponderContract {
  _Feed() : super('Feed');

  @override
  void setup() {
    addServerStreamMethod<RpcString, RpcString>(
      methodName: 'tick',
      requestCodec: _codec,
      responseCodec: _codec,
      handler: (req, {context}) async* {
        final n = int.parse(req.value);
        for (var i = 0; i < n; i++) {
          yield 'x'.rpc;
        }
      },
    );
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'echo',
      requestCodec: _codec,
      responseCodec: _codec,
      handler: (req, {context}) async => 'echo:${req.value}'.rpc,
    );
  }
}

void main() {
  test(
    'WITNESS: responses a caller already consumed are not retained',
    () async {
      final (client, server) = RpcChannelTransport.pair();
      final responder = RpcResponderEndpoint(transport: server)
        ..registerServiceContract(_Feed())
        ..start();
      final caller = RpcCallerEndpoint(transport: client);
      // Detach the no-op observer: the shape of an embedder that builds a caller
      // on a transport by hand, and the case whose cost this measures.
      await caller.closeCallerResources();
      addTearDown(() async {
        await caller.close();
        await responder.close();
      });

      var got = 0;
      await for (final _ in caller.serverStream<RpcString, RpcString>(
        serviceName: 'Feed',
        methodName: 'tick',
        request: '100'.rpc,
        requestCodec: _codec,
        responseCodec: _codec,
      )) {
        got++;
      }
      expect(got, 100, reason: 'the stream must actually have been consumed');

      // A BufferedBroadcastController replays to a late subscriber, which is how
      // what it retained becomes visible through the public API.
      var replayed = 0;
      final sub = client.incomingMessages.listen((_) => replayed++);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await sub.cancel();

      expect(
        replayed,
        0,
        reason:
            'every one of these was delivered per-stream and consumed; holding '
            'them for a listener that may never arrive is what makes a missed '
            'startCallerListening a leak',
      );
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );

  group('GUARD: what the broadcast is FOR still works', () {
    test(
      'a peer-initiated call still reaches the responder',
      () async {
        // The responder discovers new streams through the broadcast, so this is
        // the arm that fails if the skip condition is inverted or too wide.
        final (client, server) = RpcChannelTransport.pair();
        final responder = RpcResponderEndpoint(transport: server)
          ..registerServiceContract(_Feed())
          ..start();
        final caller = RpcCallerEndpoint(transport: client);
        addTearDown(() async {
          await caller.close();
          await responder.close();
        });

        final r = await caller.unaryRequest<RpcString, RpcString>(
          serviceName: 'Feed',
          methodName: 'echo',
          request: 'x'.rpc,
          requestCodec: _codec,
          responseCodec: _codec,
        );
        expect(r.value, 'echo:x');
      },
      timeout: const Timeout(Duration(seconds: 30)),
    );

    test(
      'a server stream still delivers every message in order',
      () async {
        // Skipping the broadcast must not skip the per-stream delivery, which is
        // the same message taking the other branch.
        final (client, server) = RpcChannelTransport.pair();
        final responder = RpcResponderEndpoint(transport: server)
          ..registerServiceContract(_Feed())
          ..start();
        final caller = RpcCallerEndpoint(transport: client);
        addTearDown(() async {
          await caller.close();
          await responder.close();
        });

        final got = <String>[];
        await for (final m in caller.serverStream<RpcString, RpcString>(
          serviceName: 'Feed',
          methodName: 'tick',
          request: '50'.rpc,
          requestCodec: _codec,
          responseCodec: _codec,
        )) {
          got.add(m.value);
        }
        expect(got, hasLength(50));
        expect(got.every((v) => v == 'x'), isTrue);
      },
      timeout: const Timeout(Duration(seconds: 30)),
    );

    test(
      'the RESPONDER still sees its inbound requests on the broadcast',
      () async {
        // The responder side's stream ids are peer-initiated from its point of
        // view, so its messages must NOT be skipped. Read directly off the
        // transport rather than through the pipeline, so the assertion is about
        // the broadcast and not about the call succeeding.
        final (client, server) = RpcChannelTransport.pair();
        final seen = <int>[];
        final sub = server.incomingMessages.listen((m) => seen.add(m.streamId));
        final responder = RpcResponderEndpoint(transport: server)
          ..registerServiceContract(_Feed())
          ..start();
        final caller = RpcCallerEndpoint(transport: client);
        addTearDown(() async {
          await sub.cancel();
          await caller.close();
          await responder.close();
        });

        await caller.unaryRequest<RpcString, RpcString>(
          serviceName: 'Feed',
          methodName: 'echo',
          request: 'x'.rpc,
          requestCodec: _codec,
          responseCodec: _codec,
        );

        expect(
          seen,
          isNotEmpty,
          reason:
              'the server must still be told about the client-opened stream, or '
              'it can never discover a call at all',
        );
        expect(
          seen.every((id) => id.isOdd),
          isTrue,
          reason:
              'a client opens odd ids; the server sees them as peer-initiated',
        );
      },
      timeout: const Timeout(Duration(seconds: 30)),
    );
  });
}
