// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:io';

import 'package:postgres/postgres.dart';
import 'package:rpc_data_postgres/rpc_data_postgres.dart';
import 'package:test/test.dart';

import 'nanoid.dart';

class _Item {
  const _Item({required this.id, required this.value});
  final String id;
  final int value;
}

/// Override with RPC_PG_URL to point at a throwaway instance; the default
/// is the local dev database these tests were written against.
final _url =
    Platform.environment['RPC_PG_URL'] ??
    'postgresql://postgres:00000000@localhost:5434/postgres?sslmode=disable';
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
        enableFts: true,
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
        await collection.upsert(_Item(value: i, id: NanoId.generate()));
      }

      final items = await collection.list(
        options: const QueryOptions(),
        filter: null,
        context: null,
      );
      for (var e in items) {
        print(e.data.value);
      }
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

    /// The cursor used to be the boundary record's id, re-read on the next
    /// page. Deleting that record failed the page outright and updating it
    /// moved the boundary, so rows were silently skipped or repeated.
    group('pagination survives writes to the boundary row', () {
      Future<List<String>> pageThrough(
        String collection, {
        String sortField = 'createdAt',
        Future<void> Function(String cursorRecordId)? between,
      }) async {
        final titles = <String>[];
        String? cursor;
        var guard = 0;
        do {
          final page = await storage.queryCollection(
            ListRecordsRequest(
              collection: collection,
              sort: SortOrder(field: sortField),
              options: QueryOptions(limit: 2, cursor: cursor),
            ),
          );
          titles.addAll(page.records.map((r) => r.payload['title'] as String));
          cursor = page.nextCursor;
          if (cursor != null && between != null) {
            await between(page.records.last.id);
          }
          if (++guard > 20) fail('pagination did not terminate');
        } while (cursor != null);
        return titles;
      }

      Future<List<DataRecord>> seed() async {
        final created = <DataRecord>[];
        for (var i = 0; i < 6; i++) {
          created.add(
            await repo.create(
              CreateRecordRequest(
                collection: 'notes',
                payload: {'title': 'n$i'},
              ),
            ),
          );
        }
        return created;
      }

      test('deleting the boundary row does not fail the next page', () async {
        await seed();
        var deleted = 0;
        final titles = await pageThrough(
          'notes',
          between: (boundaryId) async {
            if (deleted++ > 0) return;
            await storage.deleteRecord('notes', boundaryId);
          },
        );
        // The deleted row may or may not have been emitted already; what must
        // hold is that paging completed and never repeated a row.
        expect(titles.toSet().length, titles.length);
        expect(titles, contains('n5'));
      });

      test('updating the boundary row skips no other row', () async {
        final seeded = await seed();
        var bumped = false;
        // Sorted by the very column the update moves: the old cursor re-read
        // the boundary AFTER the write, so it resumed from the row's new
        // position at the end of the ordering and dropped everything between.
        final titles = await pageThrough(
          'notes',
          sortField: 'updatedAt',
          between: (boundaryId) async {
            if (bumped) return;
            bumped = true;
            final row = seeded.firstWhere((r) => r.id == boundaryId);
            await repo.update(
              UpdateRecordRequest(
                collection: 'notes',
                id: row.id,
                expectedVersion: row.version,
                payload: {'title': row.payload['title']},
              ),
            );
          },
        );
        expect(bumped, isTrue);
        // The moved row may legitimately be seen twice — it really did change
        // position. Nothing may be missing.
        expect(titles.toSet(), {for (var i = 0; i < 6; i++) 'n$i'});
      });
    });

    /// The batch used to read versions before the upsert and compare against
    /// that snapshot, so a concurrent writer landing in between turned a
    /// refused write into a silent success.
    test('writeRecords reports a refused record as a conflict', () async {
      final now = DateTime.now().toUtc();
      DataRecord record(String id, int version) => DataRecord(
        id: id,
        collection: 'docs',
        payload: {'v': version},
        version: version,
        createdAt: now,
        updatedAt: now,
      );

      await storage.writeRecords([record('a', 5), record('b', 1)]);

      // 'a' goes backwards and must be refused; 'b' moves forward.
      await expectLater(
        storage.writeRecords([record('a', 4), record('b', 2)]),
        throwsA(isA<RpcDataError>()),
      );

      final after = await storage.readRecords('docs', ['a', 'b']);
      expect(after['a']!.version, 5, reason: 'the refused write must not land');
      expect(after['b']!.version, 2);
    });

    test('readRecords returns only the ids that exist', () async {
      final created = await repo.create(
        const CreateRecordRequest(collection: 'docs', payload: {'title': 'x'}),
      );
      final found = await storage.readRecords('docs', [
        created.id,
        'absent-id',
      ]);
      expect(found.keys, [created.id]);
    });
  });
}
