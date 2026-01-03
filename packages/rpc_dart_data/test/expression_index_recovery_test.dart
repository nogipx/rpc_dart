// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:rpc_dart_data/rpc_dart_data.dart';
import 'package:test/test.dart';

void main() {
  group('SqliteDataStorageAdapter expression indexes', () {
    test('createCollectionIndex creates json expression index', () async {
      final adapter = await SqliteDataStorageAdapter.memory();
      addTearDown(() async {
        await adapter.dispose();
      });

      const indexName = 'priority_idx';
      const collection = 'tasks';
      const path = 'priority';

      await adapter.createCollectionIndex(
        const CreateCollectionIndexRequest(
          collection: collection,
          path: path,
          indexName: indexName,
        ),
      );

      final indexRow = await adapter.database
          .customSelect(
            'SELECT sql FROM sqlite_master WHERE type = ? AND name = ?',
            variables: const ['index', indexName],
          )
          .getSingleOrNull();

      expect(indexRow, isNotNull);
      final sql = indexRow!.read<String>('sql');
      expect(sql, contains('json_extract'));
      expect(sql, contains('payload'));

      final registryRow = await adapter.database
          .customSelect(
            'SELECT expression FROM "s_collection_index_registry" '
            'WHERE collection = ? AND path = ?',
            variables: const [collection, path],
          )
          .getSingleOrNull();

      expect(registryRow, isNotNull);
      expect(
        registryRow!.read<String>('expression'),
        contains("json_extract(payload"),
      );
    });

    test('deleteCollectionIndex removes json expression index', () async {
      final adapter = await SqliteDataStorageAdapter.memory();
      addTearDown(() async {
        await adapter.dispose();
      });

      const indexName = 'priority_idx';
      const collection = 'tasks';
      const path = 'priority';

      await adapter.createCollectionIndex(
        const CreateCollectionIndexRequest(
          collection: collection,
          path: path,
          indexName: indexName,
        ),
      );

      final beforeDelete = await adapter.database
          .customSelect(
            'SELECT 1 FROM sqlite_master WHERE type = ? AND name = ? LIMIT 1',
            variables: const ['index', indexName],
          )
          .getSingleOrNull();
      expect(beforeDelete, isNotNull);

      final removed = await adapter.deleteCollectionIndex(
        const DeleteCollectionIndexRequest(
          collection: collection,
          path: path,
          indexName: indexName,
        ),
      );

      expect(removed, isTrue);

      final afterDelete = await adapter.database
          .customSelect(
            'SELECT 1 FROM sqlite_master WHERE type = ? AND name = ? LIMIT 1',
            variables: const ['index', indexName],
          )
          .getSingleOrNull();
      expect(afterDelete, isNull);

      final registryRow = await adapter.database
          .customSelect(
            'SELECT 1 FROM "s_collection_index_registry" '
            'WHERE collection = ? AND path = ? LIMIT 1',
            variables: const [collection, path],
          )
          .getSingleOrNull();
      expect(registryRow, isNull);

      await adapter.createCollectionIndex(
        const CreateCollectionIndexRequest(
          collection: collection,
          path: path,
          indexName: indexName,
        ),
      );

      final recreated = await adapter.database
          .customSelect(
            'SELECT sql FROM sqlite_master WHERE type = ? AND name = ?',
            variables: const ['index', indexName],
          )
          .getSingleOrNull();
      expect(recreated, isNotNull);
      expect(recreated!.read<String>('sql'), contains('json_extract'));
    });

    test('restores missing indexes from registry metadata', () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'rpc_dart_data_test',
      );
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

      final connection1 = await openFileDb(
        options: SqliteConnectionOptions(nativePath: dbFile.path),
      );
      final adapter1 = SqliteDataStorageAdapter.connection(connection1);
      try {
        await adapter1.writeRecord(record);

        await adapter1.database.customStatement(
          'CREATE TABLE IF NOT EXISTS "s_collection_index_registry" ('
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
          'INSERT INTO "s_collection_index_registry" '
          '(collection, path, index_name, expression) VALUES (?, ?, ?, ?)',
          variables: ['tasks', 'priority', indexName, expression],
        );

        final existingIndex = await adapter1.database
            .customSelect(
              'SELECT 1 FROM sqlite_master WHERE type = ? AND name = ? LIMIT 1',
              variables: const ['index', indexName],
            )
            .getSingleOrNull();
        expect(existingIndex, isNull);
      } finally {
        await adapter1.dispose();
      }

      final connection2 = await openFileDb(
        options: SqliteConnectionOptions(nativePath: dbFile.path),
      );
      final adapter2 = SqliteDataStorageAdapter.connection(connection2);
      try {
        final beforeEnsure = await adapter2.database
            .customSelect(
              'SELECT 1 FROM sqlite_master WHERE type = ? AND name = ? LIMIT 1',
              variables: const ['index', 'priority_idx'],
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
              variables: const ['index', 'priority_idx'],
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
