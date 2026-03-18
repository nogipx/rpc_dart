// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'package:rpc_data/rpc_data.dart';
import 'package:test/test.dart';

void main() {
  group('DataCollection', () {
    late InMemoryDataServiceEnvironment env;
    late DataServiceCollection<_Item> collection;

    setUp(() async {
      env = await DataServiceFactory.inMemory();
      collection = DataServiceCollection<_Item>(
        collection: 'items',
        dataService: env.client,
        fromJson: (json) =>
            _Item(id: json['id'] as String, value: json['value'] as int),
        toJson: (item) => {'value': item.value},
        idSelector: (item) => item.id,
      );
    });

    tearDown(() async {
      await env.dispose();
    });

    test('list paginates when options are omitted', () async {
      for (var i = 0; i < 150; i++) {
        await collection.upsert(_Item(id: 'item-$i', value: i));
      }
      final sorted = await collection.list(options: const QueryOptions());
      expect(sorted.length, 20);
      expect(sorted.first.data.value, 0);
    });

    test('list allows explicit sort for deterministic order', () async {
      for (var i = 0; i < 150; i++) {
        await collection.upsert(_Item(id: 'item-$i', value: i));
      }

      final items = await collection.list(
        options: const QueryOptions(),
        filter: null,
        context: null,
        sort: const SortOrder(field: 'value'),
      );
      expect(items.length, 20);
      expect(items.first.data.value, 0);
      expect(
        items.map((item) => item.data.value).toSet(),
        containsAll(Iterable<int>.generate(20)),
      );
    });

    test('upsert creates and updates with optimistic locking', () async {
      final created = await collection.upsert(
        const _Item(id: 'item-1', value: 1),
      );
      expect(created.version, 1);

      final updated = await collection.upsert(
        const _Item(id: 'item-1', value: 42),
      );

      expect(updated.data.value, 42);
      expect(updated.version, created.version + 1);
    });

    test('update propagates version conflicts', () async {
      final created = await collection.upsert(
        const _Item(id: 'item-2', value: 1),
      );
      await env.client.update(
        collection: 'items',
        id: 'item-2',
        expectedVersion: created.version,
        payload: {'value': 2},
      );

      expect(
        () => collection.update(
          const _Item(id: 'item-2', value: 3),
          expectedVersion: created.version,
        ),
        throwsA(
          predicate<Object>(
            (error) =>
                error.toString().contains('VERSION_CONFLICT') ||
                error.toString().contains('Expected version'),
          ),
        ),
      );
    });

    test('delete and bulkDelete return results', () async {
      await collection.upsert(const _Item(id: 'item-a', value: 1));
      await collection.upsert(const _Item(id: 'item-b', value: 2));
      final deletedSingle = await collection.delete('item-a');
      expect(deletedSingle, isTrue);

      final deletedCount = await collection.bulkDelete(<String>[
        'item-b',
        'missing',
      ]);
      expect(deletedCount, 1);
    });

    test('watchChanges streams typed events', () async {
      final eventsFuture = collection.watchChanges().take(3).toList();

      final created = await collection.upsert(
        const _Item(id: 'item-1', value: 1),
      );
      await collection.update(
        const _Item(id: 'item-1', value: 2),
        expectedVersion: created.version,
      );
      await collection.delete('item-1');

      final events = await eventsFuture.timeout(const Duration(seconds: 5));
      final createdEvent = events.firstWhere(
        (event) => event.type == DataChangeType.created,
      );
      final updatedEvent = events.firstWhere(
        (event) => event.type == DataChangeType.updated,
      );
      final deletedEvent = events.firstWhere(
        (event) => event.type == DataChangeType.deleted,
      );

      expect(createdEvent.record?.data.value, 1);
      expect(updatedEvent.record?.data.value, 2);
      expect(deletedEvent.record, isNull);
    });
  });
}

class _Item {
  const _Item({required this.id, required this.value});
  final String id;
  final int value;
}
