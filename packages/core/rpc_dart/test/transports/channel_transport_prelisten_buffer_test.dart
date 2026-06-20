// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

/// Regression: the transport starts consuming the channel as soon as the
/// connection is up, but the endpoint pipeline subscribes to [incomingMessages]
/// slightly later. Frames that arrive in that window must NOT be lost (they used
/// to be dropped by the broadcast controller, surfacing as a client-stream whose
/// first chunk was missing its metadata).
void main() {
  group('RpcChannelTransport buffers pre-listen global-dispatch frames', () {
    Future<void> runFor(
      (RpcChannelTransport, RpcChannelTransport) Function() makePair,
    ) async {
      final (client, server) = makePair();
      addTearDown(() async {
        await client.close();
        await server.close();
      });

      final streamId = client.createStream();
      // Send BEFORE anyone listens to server.incomingMessages.
      await client.sendMessage(
        streamId,
        Uint8List.fromList([1, 2, 3, 4]),
        endStream: true,
      );
      // Let the channel deliver into the (still listener-less) transport.
      await Future<void>.delayed(const Duration(milliseconds: 20));

      // Subscribe only now — the buffered frame must still be delivered.
      final received = <RpcTransportMessage>[];
      server.incomingMessages.listen(received.add);
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(received, hasLength(1));
      expect(received.single.streamId, streamId);
      expect(received.single.payload, equals([1, 2, 3, 4]));
      expect(received.single.isEndOfStream, isTrue);
    }

    test('frame pair (RpcChannelTransport.pair)', () async {
      await runFor(RpcChannelTransport.pair);
    });

    test('zero-copy pair (RpcChannelTransport.memoryPair)', () async {
      await runFor(RpcChannelTransport.memoryPair);
    });

    test('multiple pre-listen frames flush in arrival order', () async {
      final (client, server) = RpcChannelTransport.pair();
      addTearDown(() async {
        await client.close();
        await server.close();
      });

      final sid = client.createStream();
      for (var i = 0; i < 5; i++) {
        await client.sendMessage(sid, Uint8List.fromList([i]));
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));

      final received = <int>[];
      server.incomingMessages.listen((m) => received.add(m.payload!.first));
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(received, [0, 1, 2, 3, 4]);
    });
  });
}
