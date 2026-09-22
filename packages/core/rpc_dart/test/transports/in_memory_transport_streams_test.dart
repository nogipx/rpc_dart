// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

void main() {
  group('RpcInMemoryTransport stream-id management', () {
    late IRpcTransport clientTransport;
    late IRpcTransport serverTransport;

    setUp(() {
      final pair = RpcInMemoryTransport.pair();
      clientTransport = pair.$1;
      serverTransport = pair.$2;
    });

    tearDown(() async {
      await clientTransport.close();
      await serverTransport.close();
    });

    test('client and server ids never collide', () {
      // The client uses odd ids.
      expect(clientTransport.createStream(), equals(1));
      expect(clientTransport.createStream(), equals(3));
      expect(clientTransport.createStream(), equals(5));

      // The server uses even ones.
      expect(serverTransport.createStream(), equals(2));
      expect(serverTransport.createStream(), equals(4));
      expect(serverTransport.createStream(), equals(6));
    });

    test('finishSending releases the id', () async {
      // Open a stream.
      final streamId = clientTransport.createStream();

      // Send metadata and a message.
      final metadata = RpcMetadata.forClientRequest(
        'TestService',
        'TestMethod',
      );
      await clientTransport.sendMetadata(streamId, metadata);
      await clientTransport.sendMessage(
        streamId,
        Uint8List.fromList([1, 2, 3]),
      );

      // Finish the stream; the id must come back.
      await clientTransport.finishSending(streamId);

      // A new stream gets a different id from the first.
      final newStreamId = clientTransport.createStream();
      expect(newStreamId, equals(3)); // the next odd id
    });

    test('an incoming END_STREAM releases the id', () async {
      // The first client stream, id 1.
      final streamId1 = clientTransport.createStream();
      expect(streamId1, equals(1));

      // Send a message carrying END_STREAM.
      await clientTransport.sendMetadata(
        streamId1,
        RpcMetadata.forClientRequest('Test', 'Test'),
        endStream: true,
      );

      // Let the messages be handled.
      await Future<void>.delayed(Duration(milliseconds: 1));

      // A new client stream: id 3.
      final streamId2 = clientTransport.createStream();
      expect(streamId2, equals(3));

      // Another one, finished right away.
      final streamId3 = clientTransport.createStream();
      expect(streamId3, equals(5));

      await clientTransport.sendMetadata(
        streamId3,
        RpcMetadata.forClientRequest('Test', 'Test'),
        endStream: true,
      );

      // Let it be handled.
      await Future<void>.delayed(Duration(milliseconds: 1));

      // One more: id 7, because 5 has not been released yet.
      final streamId4 = clientTransport.createStream();
      expect(streamId4, equals(7));
    });

    test('released ids are reused', () async {
      // Open, use and release a few ids.
      for (int i = 0; i < 3; i++) {
        final streamId = clientTransport.createStream(); // 1, 3, 5
        await clientTransport.sendMetadata(
          streamId,
          RpcMetadata.forClientRequest('Test', 'Test'),
          endStream: true,
        );
      }

      // A fresh transport.
      final newPair = RpcInMemoryTransport.pair();
      final newClientTransport = newPair.$1;

      try {
        // On a fresh transport the numbering starts over.
        expect(newClientTransport.createStream(), equals(1));
      } finally {
        await newClientTransport.close();
        await newPair.$2.close();
      }
    });

    test('many streams at once', () async {
      // Open several streams together.
      final totalStreams = 10;
      final streamIds = <int>[];

      // Open them.
      for (int i = 0; i < totalStreams; i++) {
        streamIds.add(clientTransport.createStream());
      }

      // Every id is distinct and odd.
      expect(streamIds.length, equals(totalStreams));
      expect(streamIds.toSet().length, equals(totalStreams)); // all distinct

      for (final id in streamIds) {
        expect(id % 2, equals(1)); // all odd
      }

      // Finish them all at once.
      final futures = <Future<void>>[];
      for (final id in streamIds) {
        futures.add(clientTransport.finishSending(id));
      }

      await Future.wait(futures);

      // Every id is released, so numbering starts from 1 again. Rebuild the
      // transport to check that.
      await clientTransport.close();
      await serverTransport.close();

      final newPair = RpcInMemoryTransport.pair();
      final newClientTransport = newPair.$1;

      try {
        expect(newClientTransport.createStream(), equals(1));
      } finally {
        await newClientTransport.close();
        await newPair.$2.close();
      }
    });
  });
}
