// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
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

    tearDown(() async {
      await journal.dispose();
    });

    Future<DataChangeEvent> writeEvent(String collection, int index) {
      return journal.recordChange(
        type: DataChangeType.created,
        collection: collection,
        id: 'item-$index',
        version: index + 1,
        occurredAt: now.add(Duration(minutes: index)),
        record: DataRecord(
          id: 'item-$index',
          collection: collection,
          payload: {'value': index},
          version: index + 1,
          createdAt: now,
          updatedAt: now,
        ),
      );
    }

    test('replay returns backlog after a known cursor', () async {
      final first = await writeEvent('tasks', 0);
      final second = await writeEvent('tasks', 1);
      final third = await writeEvent('tasks', 2);

      final replayed = await journal.replayCollection(
        'tasks',
        afterCursor: first.cursor,
      );

      expect(replayed, hasLength(2));
      expect(replayed.first.cursor, second.cursor);
      expect(replayed.last.cursor, third.cursor);
    });

    test('replay throws when cursor was pruned', () async {
      final cursors = <String>[];
      for (var i = 0; i < 5; i++) {
        cursors.add((await writeEvent('tasks', i)).cursor);
      }

      await journal.prune(collection: 'tasks', maxEvents: 2);

      expect(
        () => journal.replayCollection('tasks', afterCursor: cursors.first),
        throwsA(isA<RpcDataError>()),
      );
    });

    test('replay after prune returns remaining events', () async {
      final events = <DataChangeEvent>[];
      for (var i = 0; i < 10; i++) {
        events.add(await writeEvent('tasks', i));
      }

      final toKeepAfter = events[events.length - 3].cursor;
      await journal.prune(
        collection: 'tasks',
        retainAfter: now.add(const Duration(minutes: 7)),
      );

      final replayed = await journal.replayCollection(
        'tasks',
        afterCursor: toKeepAfter,
      );

      expect(replayed, hasLength(2));
      expect(replayed.first.cursor, events[events.length - 2].cursor);
      expect(replayed.last.cursor, events.last.cursor);
    });

    test('replay handles large backlogs deterministically', () async {
      const total = 10000;
      final stored = <String>[];
      for (var i = 0; i < total; i++) {
        final event = await writeEvent('jobs', i);
        if (i % 2000 == 0) {
          stored.add(event.cursor);
        }
      }

      for (final cursor in stored) {
        final replayed = await journal.replayCollection(
          'jobs',
          afterCursor: cursor,
        );
        final parsedCursor = int.parse(cursor);
        expect(replayed.length, total - parsedCursor);
      }
    });

    test('purge removes collection backlog and index', () async {
      await writeEvent('logs', 0);
      await journal.purgeCollection('logs');

      final replayed = await journal.replayCollection('logs');
      expect(replayed, isEmpty);

      await writeEvent('logs', 1);
      final afterPurge = await journal.replayCollection('logs');
      expect(afterPurge, hasLength(1));
    });
  });
}
