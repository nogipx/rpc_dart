// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';

import 'package:rpc_data/rpc_data.dart';
import 'package:test/test.dart';

void main() {
  group('DataService facade helpers', () {
    late InMemoryDataServiceEnvironment environment;
    late DataServiceClient client;

    setUp(() async {
      environment = await DataServiceFactory.inMemory();
      client = environment.client;
    });

    tearDown(() async {
      await environment.dispose();
    });

    test('listAllRecords iterates through all pages', () async {
      for (var i = 0; i < 120; i++) {
        await client.create(
          collection: 'tasks',
          id: 'task-$i',
          payload: {'order': i},
        );
      }

      final records = await client.listAllRecords(collection: 'tasks');

      expect(records, hasLength(120));
      final ids = records.map((record) => record.id).toSet();
      expect(ids, hasLength(120));
      expect(ids, containsAll(List.generate(120, (index) => 'task-$index')));
    });

    test('bulkUpsertStream persists streamed records', () async {
      final now = DateTime.utc(2024, 1, 1);
      final inserted = await client.bulkUpsertStream(
        records: Stream.fromIterable(
          List.generate(3, (index) {
            return DataRecord(
              id: 'bulk-$index',
              collection: 'bulk',
              payload: {'value': index},
              version: 1,
              createdAt: now.add(Duration(minutes: index)),
              updatedAt: now.add(Duration(minutes: index)),
            );
          }),
        ),
      );

      expect(inserted.map((record) => record.id), [
        'bulk-0',
        'bulk-1',
        'bulk-2',
      ]);

      final fetched = await client.list(
        collection: 'bulk',
        options: const QueryOptions(limit: 10),
      );

      expect(
        fetched.records.map((record) => record.id),
        containsAll(['bulk-0', 'bulk-1', 'bulk-2']),
      );
    });
  });
}
