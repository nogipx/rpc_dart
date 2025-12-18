import 'dart:async';

import 'package:postgres/postgres.dart' show Connection;
import 'package:rpc_dart_data/rpc_dart_data.dart';

/// Stub for platforms where Postgres is not available (e.g., web).
class PostgresDataStorageAdapter
    implements IDataStorageAdapter, ICollectionIndexStorageAdapter {
  const PostgresDataStorageAdapter._();

  static Future<PostgresDataStorageAdapter> connect({
    required Object endpoint,
    Object? settings,
    String schema = 'public',
    String tablePrefix = '',
  }) async => const PostgresDataStorageAdapter._();

  Never _unsupported() => throw UnsupportedError(
    'PostgresDataStorageAdapter is not supported on this platform.',
  );

  // Minimal surface to satisfy repository references.
  Connection get connection => _unsupported();
  String get schema => _unsupported();
  String get tablePrefix => _unsupported();
  CollectionSchemaRegistry get schemaRegistry => _unsupported();

  @override
  Future<DataRecord?> readRecord(String collection, String id) =>
      _unsupported();

  @override
  Future<Map<String, DataRecord>> readRecords(
    String collection,
    Iterable<String> ids,
  ) => _unsupported();

  @override
  Future<List<DataRecord>> readCollection(String collection) => _unsupported();

  @override
  Stream<List<DataRecord>> readCollectionChunks(
    String collection, {
    int chunkSize = BaseDataRepository.databaseExportChunkSize,
  }) => _unsupported();

  @override
  Future<ListRecordsResponse> queryCollection(ListRecordsRequest request) =>
      _unsupported();

  @override
  Future<List<String>> listCollections() => _unsupported();

  @override
  Future<SearchRecordsResponse> searchCollection(
    SearchRecordsRequest request,
  ) => _unsupported();

  @override
  Future<void> writeRecord(DataRecord record) => _unsupported();

  @override
  Future<void> writeRecords(Iterable<DataRecord> records) => _unsupported();

  @override
  Future<bool> deleteRecord(
    String collection,
    String id, {
    int? expectedVersion,
  }) => _unsupported();

  @override
  Future<int> deleteRecords(String collection, Iterable<String> ids) =>
      _unsupported();

  @override
  Future<bool> deleteCollection(String collection) => _unsupported();

  @override
  Future<void> dispose() => _unsupported();

  @override
  Future<CollectionIndex> createCollectionIndex(
    CreateCollectionIndexRequest request,
  ) => _unsupported();

  @override
  Future<bool> deleteCollectionIndex(DeleteCollectionIndexRequest request) =>
      _unsupported();
}

class PostgresDataChangeJournal implements DataChangeJournal {
  PostgresDataChangeJournal(
    Connection connection, {
    String schema = 'public',
    String tablePrefix = '',
  });

  Never _unsupported() => throw UnsupportedError(
    'PostgresDataChangeJournal is not supported on this platform.',
  );

  @override
  Future<DataChangeEvent> recordChange({
    required DataChangeType type,
    required String collection,
    required String id,
    required int version,
    required DateTime occurredAt,
    DataRecord? record,
  }) => _unsupported();

  @override
  Future<DataChangeEvent> recordDeletion({
    required String collection,
    required String id,
    required int version,
    required DateTime occurredAt,
  }) => _unsupported();

  @override
  Future<List<DataChangeEvent>> replayCollection(
    String collection, {
    String? afterCursor,
  }) => _unsupported();

  @override
  Future<void> prune({
    required String collection,
    int? maxEvents,
    DateTime? retainAfter,
  }) => _unsupported();

  @override
  Future<void> purgeCollection(String collection) => _unsupported();

  @override
  Future<void> dispose() => _unsupported();
}
