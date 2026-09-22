// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

void main() {
  group('RpcStreamIdManager', () {
    test('a client manager issues odd ids', () {
      final manager = RpcStreamIdManager(isClient: true);

      expect(manager.generateId(), equals(1));
      expect(manager.generateId(), equals(3));
      expect(manager.generateId(), equals(5));
      expect(manager.generateId(), equals(7));
      expect(manager.generateId(), equals(9));
    });

    test('a server manager issues even ids', () {
      final manager = RpcStreamIdManager(isClient: false);

      expect(manager.generateId(), equals(2));
      expect(manager.generateId(), equals(4));
      expect(manager.generateId(), equals(6));
      expect(manager.generateId(), equals(8));
      expect(manager.generateId(), equals(10));
    });

    test('releases an id and tracks which are live', () {
      final manager = RpcStreamIdManager(isClient: true);

      final id1 = manager.generateId(); // 1
      final id2 = manager.generateId(); // 3
      final id3 = manager.generateId(); // 5

      expect(manager.activeCount, equals(3));
      expect(manager.isActive(id1), isTrue);
      expect(manager.isActive(id2), isTrue);
      expect(manager.isActive(id3), isTrue);

      // Release id2.
      expect(manager.releaseId(id2), isTrue);

      expect(manager.activeCount, equals(2));
      expect(manager.isActive(id1), isTrue);
      expect(manager.isActive(id2), isFalse);
      expect(manager.isActive(id3), isTrue);

      // A second release must return false.
      expect(manager.releaseId(id2), isFalse);

      // Releasing an id that was never issued must too.
      expect(manager.releaseId(999), isFalse);
    });

    test('reset() clears every live id', () {
      final manager = RpcStreamIdManager(isClient: true);

      // Issue a few ids.
      manager.generateId();
      manager.generateId();
      manager.generateId();

      expect(manager.activeCount, equals(3));

      // Reset.
      manager.reset();

      expect(manager.activeCount, equals(0));

      // Numbering starts over.
      expect(manager.generateId(), equals(1));
    });

    test('there is a ceiling on the id', () {
      // The maxId constant holds the value we expect.
      expect(RpcStreamIdManager.maxId, equals(0x7FFFFFFF));
      expect(RpcStreamIdManager.maxId, equals(2147483647));

      // Note: overflow cannot be tested for real -- it would take issuing more
      // than a billion ids. In production an application is expected to open a
      // new connection once it reaches this ceiling.
    });

    test('released ids are reused once the ceiling is reached', () {
      final manager = RpcStreamIdManager(isClient: true, customMaxId: 9);

      final id1 = manager.generateId();
      final id2 = manager.generateId();
      final id3 = manager.generateId();

      expect(id1, equals(1));
      expect(id2, equals(3));
      expect(id3, equals(5));

      expect(manager.releaseId(id1), isTrue);
      expect(manager.releaseId(id2), isTrue);

      expect(manager.generateId(), equals(7));
      expect(manager.generateId(), equals(9));

      // Past the maximum, ids must come from the released pool.
      expect(manager.generateId(), equals(1));
      expect(manager.generateId(), equals(3));
    });

    test('releasing everything restarts the sequence', () {
      final manager = RpcStreamIdManager(isClient: false, customMaxId: 10);

      final allocated = <int>[];
      for (var i = 0; i < 5; i++) {
        allocated.add(manager.generateId());
      }

      expect(allocated, equals([2, 4, 6, 8, 10]));

      for (final id in allocated) {
        expect(manager.releaseId(id), isTrue);
      }

      expect(manager.generateId(), equals(2));
    });

    test('throws when no id is free', () {
      final manager = RpcStreamIdManager(isClient: true, customMaxId: 5);

      expect(manager.generateId(), equals(1));
      expect(manager.generateId(), equals(3));
      expect(manager.generateId(), equals(5));

      expect(manager.generateId, throwsA(isA<RpcException>()));
    });
  });

  group('through a transport', () {
    test('RpcInMemoryTransport issues and releases ids', () {
      final (clientTransport, serverTransport) = RpcInMemoryTransport.pair();

      // Ids issued on the client transport.
      final clientId1 = clientTransport.createStream(); // expected 1
      final clientId2 = clientTransport.createStream(); // expected 3

      expect(clientId1, equals(1));
      expect(clientId2, equals(3));

      // Ids issued on the server transport.
      final serverId1 = serverTransport.createStream(); // expected 2
      final serverId2 = serverTransport.createStream(); // expected 4

      expect(serverId1, equals(2));
      expect(serverId2, equals(4));

      // Releasing an id.
      expect(clientTransport.releaseStreamId(clientId1), isTrue);
      expect(serverTransport.releaseStreamId(serverId1), isTrue);

      // A second release must return false.
      expect(clientTransport.releaseStreamId(clientId1), isFalse);
      expect(serverTransport.releaseStreamId(serverId1), isFalse);
    });
  });
}
