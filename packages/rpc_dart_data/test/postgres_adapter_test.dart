// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'package:licensify/licensify.dart';
import 'package:postgres/postgres.dart';
import 'package:rpc_dart_data/rpc_dart_data.dart';
import 'package:test/test.dart';

class _Item {
  const _Item({required this.id, required this.value});
  final String id;
  final int value;
}

const _url =
    'postgresql://postgres:00000000@localhost:5433/postgres?sslmode=disable';
const _schema = 'public';
const _tablePrefix = '';

Endpoint _endpointFromUrl(String url) {
  final uri = Uri.parse(url);
  final userInfo = uri.userInfo.split(':');
  final username = userInfo.isNotEmpty ? userInfo.first : '';
  final password = userInfo.length > 1 ? userInfo.sublist(1).join(':') : '';
  return Endpoint(
    host: uri.host,
    port: uri.port == 0 ? 5432 : uri.port,
    database: uri.pathSegments.isNotEmpty ? uri.pathSegments.first : '',
    username: username,
    password: password.isEmpty ? null : password,
  );
}

void main() {
  group('Postgres adapter', () {
    late Connection connection;
    late PostgresDataStorageAdapter storage;
    late PostgresDataRepository repo;

    setUp(() async {
      connection = await Connection.openFromUrl(_url);
      storage = await PostgresDataStorageAdapter.connect(
        endpoint: _endpointFromUrl(_url),
        schema: _schema,
        tablePrefix: _tablePrefix,
        settings: const ConnectionSettings(sslMode: SslMode.disable),
      );
      repo = PostgresDataRepository(storage: storage);
      // // Очистка коллекций перед каждым тестом, чтобы не брать старые данные.
      await storage.deleteCollection('notes');
      await storage.deleteCollection('docs');
      await storage.deleteCollection('filters');
      await storage.deleteCollection('utc');
    });

    tearDown(() async {
      // Чистим коллекции, чтобы тесты были идempotent при повторных запусках.
      await storage.deleteCollection('notes');
      await storage.deleteCollection('docs');
      await storage.deleteCollection('filters');
      await storage.deleteCollection('utc');
      await storage.dispose();
      await connection.close();
    });

    test('list allows explicit sort for deterministic order', () async {
      final env = await DataServiceFactory.inMemory(repository: repo);
      final collection = DataServiceCollection<_Item>(
        collection: 'items',
        dataService: env.client,
        fromJson: (json) =>
            _Item(id: json['id'] as String, value: json['value'] as int),
        toJson: (item) => {'value': item.value},
        idSelector: (item) => item.id,
      );
      for (var i = 0; i < 150; i++) {
        await collection.upsert(_Item(value: i, id: Licensify.nanoId()));
      }

      final items = await collection.list(
        options: const QueryOptions(),
        filter: null,
        context: null,
      );
      items.forEach((e) => print(e.data.value));
      expect(items.length, 20);
      expect(items.first.data.value, 0);
      expect(
        items.map((item) => item.data.value).toSet(),
        containsAll(Iterable<int>.generate(20)),
      );
    });

    test('CRUD + query pagination work per collection', () async {
      final created1 = await repo.create(
        const CreateRecordRequest(
          collection: 'notes',
          payload: {'title': 'first'},
        ),
      );
      final created2 = await repo.create(
        const CreateRecordRequest(
          collection: 'notes',
          payload: {'title': 'second'},
        ),
      );

      final fetched = await repo.get(
        GetRecordRequest(collection: 'notes', id: created1.id),
      );
      expect(fetched?.payload['title'], equals('first'));

      final updated = await repo.update(
        UpdateRecordRequest(
          collection: 'notes',
          id: created1.id,
          expectedVersion: created1.version,
          payload: {'title': 'first-updated'},
        ),
      );
      expect(updated.version, equals(created1.version + 1));
      expect(updated.payload['title'], equals('first-updated'));

      final page1 = await repo.list(
        const ListRecordsRequest(
          collection: 'notes',
          sort: SortOrder(field: 'createdAt'),
          options: QueryOptions(limit: 1),
        ),
      );
      expect(page1.records.length, equals(1));
      expect(page1.nextCursor, isNotNull);

      final page2 = await repo.list(
        ListRecordsRequest(
          collection: 'notes',
          sort: const SortOrder(field: 'createdAt'),
          options: QueryOptions(limit: 1, cursor: page1.nextCursor),
        ),
      );
      expect(page2.records.length, equals(1));
      expect({
        page1.records.first.id,
        page2.records.first.id,
      }, containsAll({created1.id, created2.id}));

      final deleted = await repo.delete(
        DeleteRecordRequest(
          collection: 'notes',
          id: created2.id,
          expectedVersion: created2.version,
        ),
      );
      expect(deleted, isTrue);
    });

    test('search and deleteCollection', () async {
      await repo.create(
        const CreateRecordRequest(
          collection: 'docs',
          payload: {'body': 'full text search ok'},
        ),
      );
      await repo.create(
        const CreateRecordRequest(
          collection: 'docs',
          payload: {'body': 'another document'},
        ),
      );

      final search = await repo.search(
        const SearchRecordsRequest(
          collection: 'docs',
          query: 'search',
          options: QueryOptions(limit: 10),
        ),
      );
      expect(search.totalHits, equals(1));
      expect(search.records.single.payload['body'], contains('search'));

      final dropped = await repo.deleteCollection(
        const DeleteCollectionRequest(collection: 'docs'),
      );
      expect(dropped, isTrue);

      final collections = await storage.listCollections();
      expect(collections.contains('docs'), isFalse);
    });

    test('filters, ranges, totalCount, indexes', () async {
      await repo.create(
        const CreateRecordRequest(
          collection: 'filters',
          payload: {'title': 'alpha', 'value': 1, 'text': 'hello world'},
        ),
      );
      await repo.create(
        const CreateRecordRequest(
          collection: 'filters',
          payload: {'title': 'beta', 'value': 2, 'text': 'middle text'},
        ),
      );
      await repo.create(
        const CreateRecordRequest(
          collection: 'filters',
          payload: {'title': 'gamma', 'value': 5, 'text': 'search target'},
        ),
      );

      final indexed = await storage.createCollectionIndex(
        const CreateCollectionIndexRequest(
          collection: 'filters',
          path: 'value',
        ),
      );
      expect(indexed.collection, equals('filters'));
      expect(indexed.path, equals('value'));

      final filtered = await repo.list(
        ListRecordsRequest(
          collection: 'filters',
          filter: RecordFilter(
            equals: {'title': 'gamma'},
            range: {'value': const RangeFilter(min: 3, includeMin: true)},
            containsTerms: const ['target'],
          ),
          options: const QueryOptions(limit: 10, includeTotalCount: true),
        ),
      );
      expect(filtered.records.length, equals(1));
      expect(filtered.totalCount, equals(1));
      expect(filtered.records.single.payload['title'], equals('gamma'));

      final rangeOnly = await repo.list(
        ListRecordsRequest(
          collection: 'filters',
          filter: const RecordFilter(
            range: {'value': RangeFilter(min: 2, max: 5)},
          ),
          sort: const SortOrder(field: 'value'),
          options: const QueryOptions(limit: 2),
        ),
      );
      expect(rangeOnly.records.length, equals(2));
      expect(rangeOnly.records.first.payload['value'], equals(2));
      expect(rangeOnly.records.last.payload['value'], equals(5));

      final removed = await storage.deleteCollectionIndex(
        DeleteCollectionIndexRequest(
          collection: 'filters',
          indexName: indexed.indexName,
          path: 'value',
        ),
      );
      expect(removed, isTrue);
    });

    test('timestamps are stored and read as UTC', () async {
      final created = await repo.create(
        const CreateRecordRequest(
          collection: 'utc',
          payload: {'title': 'utc check'},
        ),
      );
      expect(created.createdAt.isUtc, isTrue);
      expect(created.updatedAt.isUtc, isTrue);

      final updated = await repo.update(
        UpdateRecordRequest(
          collection: 'utc',
          id: created.id,
          expectedVersion: created.version,
          payload: {'title': 'utc check 2'},
        ),
      );
      expect(updated.createdAt.isUtc, isTrue);
      expect(updated.updatedAt.isUtc, isTrue);
      expect(updated.updatedAt.isAfter(created.updatedAt), isTrue);
    });
  });
}
