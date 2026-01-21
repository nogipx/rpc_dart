// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'package:rpc_data/rpc_data.dart';
import 'package:test/test.dart';

void main() {
  group('InMemoryDataChangeJournal', () {
    late InMemoryDataChangeJournal journal;
    final now = DateTime.utc(2024, 1, 1);

    setUp(() {
      journal = InMemoryDataChangeJournal();
    });

    test('records changes and replays since cursor', () async {
      final first = await journal.recordChange(
        type: DataChangeType.created,
        collection: 'tasks',
        id: 'task-1',
        version: 1,
        occurredAt: now,
        record: DataRecord(
          id: 'task-1',
          collection: 'tasks',
          payload: const {'value': 1},
          version: 1,
          createdAt: now,
          updatedAt: now,
        ),
      );
      final second = await journal.recordChange(
        type: DataChangeType.updated,
        collection: 'tasks',
        id: 'task-1',
        version: 2,
        occurredAt: now.add(const Duration(minutes: 1)),
      );

      final replayed = await journal.replayCollection(
        'tasks',
        afterCursor: first.cursor,
      );

      expect(replayed, hasLength(1));
      expect(replayed.single.cursor, second.cursor);
      expect(replayed.single.type, DataChangeType.updated);
    });

    test('replay throws when cursor unknown', () async {
      await journal.recordChange(
        type: DataChangeType.created,
        collection: 'notes',
        id: 'note-1',
        version: 1,
        occurredAt: now,
      );

      await expectLater(
        () => journal.replayCollection('notes', afterCursor: 'missing'),
        throwsA(isA<RpcDataError>()),
      );
    });

    test('prune respects retainAfter and maxEvents', () async {
      for (var i = 0; i < 5; i++) {
        await journal.recordChange(
          type: DataChangeType.updated,
          collection: 'jobs',
          id: 'job-$i',
          version: i + 1,
          occurredAt: now.add(Duration(minutes: i)),
        );
      }

      await journal.prune(
        collection: 'jobs',
        retainAfter: now.add(const Duration(minutes: 2)),
        maxEvents: 2,
      );

      final remaining = await journal.replayCollection('jobs');
      expect(remaining, hasLength(2));
      expect(
        remaining.first.occurredAt.compareTo(
          now.add(const Duration(minutes: 2)),
        ),
        greaterThanOrEqualTo(0),
      );
    });

    test('purgeCollection clears backlog', () async {
      await journal.recordChange(
        type: DataChangeType.snapshot,
        collection: 'logs',
        id: 'log-1',
        version: 1,
        occurredAt: now,
      );

      await journal.purgeCollection('logs');
      final remaining = await journal.replayCollection('logs');
      expect(remaining, isEmpty);
    });

    test('recordDeletion inserts deleted events', () async {
      final deleted = await journal.recordDeletion(
        collection: 'archive',
        id: 'item-1',
        version: 5,
        occurredAt: now,
      );

      expect(deleted.type, DataChangeType.deleted);
      final replayed = await journal.replayCollection('archive');
      expect(replayed.single.type, DataChangeType.deleted);
    });
  });
}
