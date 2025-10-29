import 'package:rpc_dart_data/rpc_dart_data.dart';
import 'package:test/test.dart';

void main() {
  group('DriftDataStorageAdapter.writeRecords', () {
    test('batches SQL statements for multi-record writes', () async {
      final executed = <({String sql, List<Object?> args})>[];
      final storage = DriftDataStorageAdapter.memory(
        statementObserver: (sql, arguments) {
          if (sql.startsWith('INSERT INTO "c_notes"')) {
            executed.add((sql: sql, args: arguments));
          }
        },
      );
      addTearDown(storage.dispose);

      final baseTime = DateTime.utc(2024, 1, 1);
      final records = List.generate(200, (index) {
        final timestamp = baseTime.add(Duration(microseconds: index));
        return DataRecord(
          id: 'note-$index',
          collection: 'notes',
          tenantId: index.isEven ? 'tenant-a' : null,
          payload: {'title': 'Note $index'},
          version: 1,
          createdAt: timestamp,
          updatedAt: timestamp,
        );
      });

      await storage.writeRecords(records);

      expect(executed, isNotEmpty);
      expect(executed.length, lessThan(records.length));
      final totalArgs =
          executed.fold<int>(0, (sum, entry) => sum + entry.args.length);
      expect(totalArgs, records.length * 6);
      expect(executed.first.sql, contains('VALUES (?, ?, ?, ?, ?, ?),'));
    });

    test('upserts bulk updates atomically', () async {
      final storage = DriftDataStorageAdapter.memory();
      addTearDown(storage.dispose);

      final baseTime = DateTime.utc(2024, 5, 1);
      final initialRecords = List.generate(250, (index) {
        final timestamp = baseTime.add(Duration(minutes: index));
        return DataRecord(
          id: 'record-$index',
          collection: 'bulk',
          tenantId: index.isOdd ? 'tenant-b' : null,
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
              tenantId: record.tenantId,
              payload: {
                'value': record.payload['value'],
                'updated': true,
              },
              version: record.version + 1,
              createdAt: record.createdAt,
              updatedAt: record.updatedAt.add(const Duration(days: 1)),
            ),
          )
          .toList(growable: false);

      await storage.writeRecords(updates);

      final persisted = await storage.readCollection('bulk');
      expect(persisted, hasLength(initialRecords.length));
      final persistedById = {
        for (final record in persisted) record.id: record,
      };
      for (final update in updates) {
        final stored = persistedById[update.id];
        expect(stored, isNotNull, reason: 'missing record ${update.id}');
        expect(stored!.version, update.version);
        expect(stored.payload, update.payload);
        expect(stored.updatedAt, update.updatedAt);
        expect(stored.createdAt, update.createdAt);
        expect(stored.tenantId, update.tenantId);
      }
    });
  });
}
