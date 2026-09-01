// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// InMemoryDataChangeJournal routed every access through _history(), which
// putIfAbsent's into BOTH backing maps. The read-only operations went through
// it too, so replaying or pruning a collection that was never written to left
// an empty entry behind. Collection names come from the caller, so repeated
// reads of unknown names grew the maps without bound -- and neither map is
// observable from outside, hence trackedCollectionCount.

import 'package:rpc_data/rpc_data.dart';
import 'package:test/test.dart';

void main() {
  group(
    'InMemoryDataChangeJournal retains no state for unknown collections',
    () {
      test('replaying an unknown collection materialises nothing', () async {
        final journal = InMemoryDataChangeJournal();

        for (var i = 0; i < 25; i++) {
          expect(await journal.replayCollection('ghost-$i'), isEmpty);
        }

        expect(
          journal.trackedCollectionCount,
          0,
          reason: 'each replay of an unknown name left an empty entry before',
        );
        await journal.dispose();
      });

      test('pruning an unknown collection materialises nothing', () async {
        final journal = InMemoryDataChangeJournal();

        for (var i = 0; i < 25; i++) {
          await journal.prune(collection: 'ghost-$i', maxEvents: 10);
        }

        expect(journal.trackedCollectionCount, 0);
        await journal.dispose();
      });

      test('replaying an unknown collection with a cursor still throws', () {
        final journal = InMemoryDataChangeJournal();
        expect(
          () => journal.replayCollection('ghost', afterCursor: '7'),
          throwsA(isA<RpcDataError>()),
        );
        expect(journal.trackedCollectionCount, 0);
      });

      test('a written collection is tracked and replays correctly', () async {
        final journal = InMemoryDataChangeJournal();

        final first = await journal.recordChange(
          type: DataChangeType.created,
          collection: 'real',
          id: 'a',
          version: 1,
          occurredAt: DateTime.utc(2026),
        );
        await journal.recordChange(
          type: DataChangeType.updated,
          collection: 'real',
          id: 'a',
          version: 2,
          occurredAt: DateTime.utc(2026, 1, 2),
        );

        expect(journal.trackedCollectionCount, 1);
        expect(await journal.replayCollection('real'), hasLength(2));
        expect(
          await journal.replayCollection('real', afterCursor: first.cursor),
          hasLength(1),
        );

        // Pruning a real collection still works and keeps it tracked.
        await journal.prune(collection: 'real', maxEvents: 1);
        expect(await journal.replayCollection('real'), hasLength(1));
        expect(journal.trackedCollectionCount, 1);

        await journal.purgeCollection('real');
        expect(journal.trackedCollectionCount, 0);
        await journal.dispose();
      });
    },
  );
}
