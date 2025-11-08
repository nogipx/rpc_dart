import 'package:rpc_dart_data/rpc_dart_data.dart';
import 'package:test/test.dart';

class _TestRepository extends BaseDataRepository {
  _TestRepository(super.storage) : super(clock: () => DateTime.utc(2024, 1, 1));
}

class _ThrowingAdapter implements DataStorageAdapter {
  _ThrowingAdapter(this._delegate);

  final InMemoryStorageAdapter _delegate;

  @override
  Future<AggregateMetricsResponse> aggregateCollection(
    AggregateMetricsRequest request,
  ) async {
    throw UnimplementedError('aggregate');
  }

  @override
  Future<SearchRecordsResponse> searchCollection(
    SearchRecordsRequest request,
  ) async {
    throw UnimplementedError('search');
  }

  @override
  Future<ListRecordsResponse> queryCollection(
      ListRecordsRequest request) async {
    throw UnimplementedError('list');
  }

  @override
  Future<bool> deleteCollection(String collection) {
    return _delegate.deleteCollection(collection);
  }

  @override
  Future<bool> deleteRecord(String collection, String id) {
    return _delegate.deleteRecord(collection, id);
  }

  @override
  Future<int> deleteRecords(String collection, Iterable<String> ids) {
    return _delegate.deleteRecords(collection, ids);
  }

  @override
  Future<void> dispose() {
    return _delegate.dispose();
  }

  @override
  Future<List<String>> listCollections() {
    return _delegate.listCollections();
  }

  @override
  Future<DataRecord?> readRecord(String collection, String id) {
    return _delegate.readRecord(collection, id);
  }

  @override
  Future<Map<String, DataRecord>> readRecords(
    String collection,
    Iterable<String> ids,
  ) {
    return _delegate.readRecords(collection, ids);
  }

  @override
  Future<List<DataRecord>> readCollection(String collection) {
    return _delegate.readCollection(collection);
  }

  @override
  Stream<List<DataRecord>> readCollectionChunks(
    String collection, {
    int chunkSize = BaseDataRepository.databaseExportChunkSize,
  }) {
    return _delegate.readCollectionChunks(
      collection,
      chunkSize: chunkSize,
    );
  }

  @override
  Future<void> writeRecord(DataRecord record) {
    return _delegate.writeRecord(record);
  }

  @override
  Future<void> writeRecords(Iterable<DataRecord> records) {
    return _delegate.writeRecords(records);
  }
}

void main() {
  group('InMemoryStorageAdapter queries', () {
    late InMemoryStorageAdapter storage;
    late InMemoryDataRepository repository;

    setUp(() {
      storage = InMemoryStorageAdapter();
      repository = InMemoryDataRepository(storage: storage);
    });

    tearDown(() async {
      await repository.dispose();
    });

    Future<void> seedTasks() async {
      final now = DateTime.utc(2024, 1, 1);
      for (var i = 0; i < 5; i++) {
        final status = i.isEven ? 'open' : 'closed';
        await storage.writeRecord(
          DataRecord(
            id: 'task-$i',
            collection: 'tasks',
            payload: {'priority': i, 'status': status},
            version: 1,
            createdAt: now.add(Duration(minutes: i)),
            updatedAt: now.add(Duration(minutes: i)),
          ),
        );
      }
    }

    test('list applies filter, sort, limit and offset', () async {
      await seedTasks();

      final response = await repository.list(
        const ListRecordsRequest(
          collection: 'tasks',
          filter: RecordFilter(equals: {'status': 'open'}),
          sort: SortOrder(field: 'priority', descending: true),
          options: QueryOptions(limit: 2, offset: 1, includeTotalCount: true),
        ),
      );

      expect(response.totalCount, 3);
      expect(response.records, hasLength(2));
      expect(response.records.first.payload['priority'], 2);
      expect(response.records.last.payload['priority'], 0);
      expect(response.nextCursor, 'task-0');
    });

    test('search applies filters and offset', () async {
      final now = DateTime.utc(2024, 1, 1);
      for (final entry in [
        ('alpha', 'draft'),
        ('beta', 'published'),
        ('gamma', 'draft'),
        ('delta', 'draft'),
      ]) {
        await storage.writeRecord(
          DataRecord(
            id: entry.$1,
            collection: 'articles',
            payload: {'title': 'Hello ${entry.$1}', 'state': entry.$2},
            version: 1,
            createdAt: now,
            updatedAt: now,
          ),
        );
      }

      final response = await repository.search(
        const SearchRecordsRequest(
          collection: 'articles',
          query: 'hello',
          filter: RecordFilter(equals: {'state': 'draft'}),
          options: QueryOptions(limit: 1, offset: 1),
        ),
      );

      expect(response.totalHits, 3);
      expect(response.records, hasLength(1));
      expect(response.records.single.id, 'delta');
    });
  });

  group('DriftDataStorageAdapter queries', () {
    late DriftDataStorageAdapter storage;
    late DriftDataRepository repository;
    late List<({String sql, List<Object?> args})> statements;

    setUp(() {
      statements = <({String sql, List<Object?> args})>[];
      storage = DriftDataStorageAdapter.memory(
        statementObserver: (sql, args) {
          statements.add((sql: sql, args: List<Object?>.from(args)));
        },
      );
      repository = DriftDataRepository(storage: storage);
    });

    tearDown(() async {
      await repository.dispose();
    });

    Future<void> seedTasks() async {
      for (var i = 0; i < 5; i++) {
        final status = i.isEven ? 'open' : 'closed';
        await repository.create(
          CreateRecordRequest(
            collection: 'tasks',
            id: 'task-$i',
            payload: {'priority': i, 'status': status},
          ),
        );
      }
    }

    test('list delegates pagination to SQLite', () async {
      await seedTasks();

      statements.clear();
      final response = await repository.list(
        const ListRecordsRequest(
          collection: 'tasks',
          filter: RecordFilter(equals: {'status': 'open'}),
          sort: SortOrder(field: 'priority', descending: true),
          options: QueryOptions(limit: 1, offset: 1, includeTotalCount: true),
        ),
      );

      expect(response.totalCount, 3);
      expect(response.records, hasLength(1));
      expect(response.records.single.payload['priority'], 2);
      expect(response.nextCursor, 'task-2');

      final pagedQuery = statements.firstWhere(
        (entry) =>
            entry.sql.contains('FROM "tasks"') &&
            entry.sql.contains('ORDER BY') &&
            entry.sql.contains('LIMIT ? OFFSET ?'),
      );
      expect(pagedQuery.args.sublist(pagedQuery.args.length - 2), [1, 1]);

      final countQuery = statements.firstWhere(
        (entry) =>
            entry.sql.contains('COUNT(*)') &&
            entry.sql.contains('FROM "tasks"'),
      );
      expect(countQuery.args, contains('open'));
    });

    test('search honours offset on SQLite backend', () async {
      for (final id in ['note-a', 'note-b', 'note-c']) {
        await repository.create(
          CreateRecordRequest(
            collection: 'notes',
            id: id,
            payload: {'title': 'Note $id'},
          ),
        );
      }

      statements.clear();
      final response = await repository.search(
        const SearchRecordsRequest(
          collection: 'notes',
          query: 'note',
          options: QueryOptions(limit: 1, offset: 1),
        ),
      );

      expect(response.records, hasLength(1));
      expect(response.totalHits, 3);
      expect(response.records.single.id, 'note-b');

      final ftsQuery = statements.firstWhere(
        (entry) =>
            entry.sql.contains('MATCH ?') &&
            entry.sql.contains('LIMIT ? OFFSET ?'),
      );
      expect(ftsQuery.args.last, 1);
      expect(ftsQuery.args[ftsQuery.args.length - 2], 2);
    });
  });

  group('BaseDataRepository contract enforcement', () {
    test('throws RpcDataError when adapter lacks query support', () async {
      final adapter = _ThrowingAdapter(InMemoryStorageAdapter());
      final repository = _TestRepository(adapter);

      await expectLater(
        repository.list(const ListRecordsRequest(collection: 'demo')),
        throwsA(
          isA<RpcDataError>().having(
            (error) => error.message,
            'message',
            contains('does not support list queries'),
          ),
        ),
      );

      await repository.dispose();
    });
  });
}
