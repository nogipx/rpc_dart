import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:path/path.dart' as p;
import 'package:rpc_dart_data/src/drift_storage.dart';
import 'package:rpc_dart_data/src/models.dart';
import 'package:test/test.dart';

void main() {
  group('DriftDataStorageAdapter expression indexes', () {
    test('restores missing indexes from registry metadata', () async {
      final tempDir = await Directory.systemTemp.createTemp('rpc_dart_data_test');
      addTearDown(() async {
        if (await tempDir.exists()) {
          await tempDir.delete(recursive: true);
        }
      });
      final dbFile = File(p.join(tempDir.path, 'data.sqlite'));

      final now = DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
      final record = DataRecord(
        id: 'task-1',
        collection: 'tasks',
        payload: const {'priority': 1},
        version: 1,
        createdAt: now,
        updatedAt: now,
      );

      final adapter1 = DriftDataStorageAdapter(NativeDatabase(dbFile));
      try {
        await adapter1.writeRecord(record);

        await adapter1.database.customStatement(
          'CREATE TABLE IF NOT EXISTS collection_index_registry ('
          'collection TEXT NOT NULL, '
          'path TEXT NOT NULL, '
          'index_name TEXT NOT NULL UNIQUE, '
          'expression TEXT NOT NULL, '
          'PRIMARY KEY (collection, path)'
          ')',
        );

        const indexName = 'priority_idx';
        const expression = "json_extract(payload, '\$.\"priority\"')";
        await adapter1.database.customStatement(
          'INSERT INTO collection_index_registry '
          '(collection, path, index_name, expression) VALUES (?, ?, ?, ?)',
          ['tasks', 'priority', indexName, expression],
        );

        final existingIndex = await adapter1.database
            .customSelect(
              'SELECT 1 FROM sqlite_master WHERE type = ? AND name = ? LIMIT 1',
              variables: const [
                Variable<String>('index'),
                Variable<String>(indexName),
              ],
            )
            .getSingleOrNull();
        expect(existingIndex, isNull);
      } finally {
        await adapter1.dispose();
      }

      final adapter2 = DriftDataStorageAdapter(NativeDatabase(dbFile));
      try {
        final beforeEnsure = await adapter2.database
            .customSelect(
              'SELECT 1 FROM sqlite_master WHERE type = ? AND name = ? LIMIT 1',
              variables: const [
                Variable<String>('index'),
                Variable<String>('priority_idx'),
              ],
            )
            .getSingleOrNull();
        expect(beforeEnsure, isNull);

        final updatedRecord = record.copyWith(
          version: 2,
          updatedAt: now.add(const Duration(seconds: 1)),
        );
        await adapter2.writeRecord(updatedRecord);

        final indexRow = await adapter2.database
            .customSelect(
              'SELECT sql FROM sqlite_master WHERE type = ? AND name = ?',
              variables: const [
                Variable<String>('index'),
                Variable<String>('priority_idx'),
              ],
            )
            .getSingleOrNull();

        expect(indexRow, isNotNull);
        expect(indexRow!.read<String>('sql'), contains('json_extract'));
      } finally {
        await adapter2.dispose();
      }
    });
  });
}
