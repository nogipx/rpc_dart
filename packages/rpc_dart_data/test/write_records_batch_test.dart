// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'package:rpc_dart_data/rpc_dart_data.dart';
import 'package:test/test.dart';

void main() {
  group('SqliteDataStorageAdapter.writeRecords', () {
    test('upserts bulk updates atomically', () async {
      final storage = await SqliteDataStorageAdapter.memory();
      addTearDown(storage.dispose);

      final baseTime = DateTime.utc(2024, 5, 1);
      final initialRecords = List.generate(250, (index) {
        final timestamp = baseTime.add(Duration(minutes: index));
        return DataRecord(
          id: 'record-$index',
          collection: 'bulk',
          payload: {'value': index},
          version: 1,
          createdAt: timestamp,
          updatedAt: timestamp,
        );
      });

      await storage.writeRecords(initialRecords);

      final updates = initialRecords
          .map(
            (record) => DataRecord(
              id: record.id,
              collection: record.collection,
              payload: {'value': record.payload['value'], 'updated': true},
              version: record.version + 1,
              createdAt: record.createdAt,
              updatedAt: record.updatedAt.add(const Duration(days: 1)),
            ),
          )
          .toList(growable: false);

      await storage.writeRecords(updates);

      final persisted = await storage.readCollection('bulk');
      expect(persisted, hasLength(initialRecords.length));
      final persistedById = {for (final record in persisted) record.id: record};
      for (final update in updates) {
        final stored = persistedById[update.id];
        expect(stored, isNotNull, reason: 'missing record ${update.id}');
        expect(stored!.version, update.version);
        expect(stored.payload, update.payload);
        expect(stored.updatedAt, update.updatedAt);
        expect(stored.createdAt, update.createdAt);
      }
    });
  });
}
