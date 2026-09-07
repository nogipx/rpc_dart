// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// RpcChannelTransport._statusSeen records which stream ids the peer has sent a
// gRPC status for. It is what tells a COMPLETED response from a TRUNCATED one
// at end-of-stream, and it is keyed by a stream id the PEER chooses.
//
// Every other peer-keyed structure in that file is bounded -- the flow-control
// maps at maxActiveStreams, _finishedStreams at its own cap -- each with a
// comment explaining that the transport does this bookkeeping BEFORE the
// responder pipeline decides whether an id is a legitimate stream at all.
// _statusSeen was the one that was not. Measured with 400,000 metadata-only
// frames carrying `grpc-status` on ids the victim never minted, which the
// responder pipeline ignores as no-op frames:
//
//     flow-control maps : advertised 4096   <- at the cap
//     statusSeen        : 399997            <- unbounded
//     after the fix     : 0
//
// on a connection that had never carried a call. Two changes, and both halves
// are witnessed below: the set now only records ids that have a per-stream
// controller (the only ids it is ever READ for), and releaseStreamId() prunes
// it, exactly as it already prunes _finishedStreams.

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

Future<int> _statusSeen(IRpcTransport t) async {
  final v = (await t.health()).details['statusSeen'];
  return v is int ? v : -1;
}

/// How the consumer of [id] saw the stream end.
Future<String> _endShape(
  RpcChannelTransport client,
  RpcChannelTransport server,
  int id, {
  required bool withStatus,
}) async {
  final events = <String>[];
  final done = Completer<void>();
  client
      .getMessagesForStream(id)
      .listen(
        (m) => events.add(m.payload != null ? 'data' : 'meta'),
        // Deliberately does NOT complete here: the controller closes right
        // after the error, and settling on the first terminal event would hide
        // whether the stream ends at all.
        onError: (Object e) => events.add('ERROR'),
        onDone: () {
          events.add('done');
          if (!done.isCompleted) done.complete();
        },
      );

  await server.sendMessage(id, RpcMessageFrame.encode(Uint8List(8)));
  await server.sendMetadata(
    id,
    RpcMetadata([if (withStatus) const RpcHeader(RpcHeaders.grpcStatus, '0')]),
    endStream: true,
  );
  await done.future.timeout(
    const Duration(seconds: 5),
    onTimeout: () => events.add('TIMEOUT'),
  );
  return events.join(' -> ');
}

void main() {
  group('_statusSeen is bounded by our own traffic', () {
    // WITNESS 1: the flood. Before the fix this ended at 399997 with 400,000
    // frames; 20,000 is enough to tell "bounded" from "one entry per frame".
    test('a peer naming ids we never minted moves nothing', () async {
      final (client, server) = RpcChannelTransport.pair();

      for (var i = 0; i < 20000; i++) {
        await server.sendMetadata(
          2 + i * 2,
          RpcMetadata([const RpcHeader(RpcHeaders.grpcStatus, '0')]),
        );
      }
      await Future<void>.delayed(const Duration(milliseconds: 200));

      expect(
        await _statusSeen(client),
        0,
        reason:
            'these ids have no per-stream controller, so an entry for them can '
            'never be read -- only retained',
      );

      await client.close();
      await server.close();
    });

    // WITNESS 2: the other half of the fix. This id IS ours, so the entry is
    // recorded; a status with no end flag means no terminal frame ever prunes
    // it, and teardown has to.
    test(
      'a stream torn down after a status with no end flag is pruned',
      () async {
        final (client, server) = RpcChannelTransport.pair();

        final id = client.createStream();
        client.getMessagesForStream(id).listen((_) {}, onError: (Object _) {});
        await server.sendMetadata(
          id,
          RpcMetadata([const RpcHeader(RpcHeaders.grpcStatus, '0')]),
        );
        await Future<void>.delayed(const Duration(milliseconds: 100));
        expect(
          await _statusSeen(client),
          1,
          reason: 'the entry must be recorded for a stream we opened',
        );

        client.releaseStreamId(id);
        expect(
          await _statusSeen(client),
          0,
          reason: 'teardown is the only chance left to prune it',
        );

        await client.close();
        await server.close();
      },
    );
  });

  group('GUARD: truncation detection still works', () {
    // The whole point of the set. If the gate above kept an entry from being
    // recorded for a real call, a completed response would start reporting as
    // truncated -- and if it recorded too much, a truncated one would read as
    // clean. Both directions are pinned.
    test('a response ending without a status is an error', () async {
      final (client, server) = RpcChannelTransport.pair();
      final id = client.createStream();

      expect(
        await _endShape(client, server, id, withStatus: false),
        'data -> ERROR -> done',
      );

      await client.close();
      await server.close();
    });

    test('a response ending WITH a status is a clean end', () async {
      final (client, server) = RpcChannelTransport.pair();
      final id = client.createStream();

      expect(
        await _endShape(client, server, id, withStatus: true),
        'data -> meta -> done',
      );

      await client.close();
      await server.close();
    });
  });

  group('GUARD: ordinary calls are unaffected', () {
    test('real traffic leaves the set at zero', () async {
      final (client, server) = RpcChannelTransport.pair();
      final caller = RpcCallerEndpoint(transport: client);
      final responder = RpcResponderEndpoint(transport: server);
      responder.registerServiceContract(_Svc());
      responder.start();

      for (var i = 0; i < 20; i++) {
        final r = await caller.unaryRequest<RpcString, RpcString>(
          serviceName: 'Svc',
          methodName: 'echo',
          request: 'x'.rpc,
          requestCodec: _codec,
          responseCodec: _codec,
        );
        expect(r.value, 'x');
      }
      await Future<void>.delayed(const Duration(milliseconds: 200));

      expect(await _statusSeen(client), 0);

      await caller.close();
      await responder.close();
    });
  });
}

final class _Svc extends RpcResponderContract {
  _Svc() : super('Svc');

  @override
  void setup() {
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'echo',
      handler: (r, {RpcContext? context}) async => r,
      requestCodec: _codec,
      responseCodec: _codec,
    );
  }
}
