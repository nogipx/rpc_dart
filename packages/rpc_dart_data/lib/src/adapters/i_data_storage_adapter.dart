part of '_index.dart';

/// Адаптер хранилища, который можно реализовать поверх любого backend-а
/// (in-memory, SQLite, Postgres и т.д.).
abstract interface class IDataStorageAdapter {
  /// Ensure the underlying storage is initialised and ready to serve traffic.
  Future<void> ensureReady({bool validateIntegrity = true});

  Future<DataRecord?> readRecord(String collection, String id);

  Future<Map<String, DataRecord>> readRecords(
    String collection,
    Iterable<String> ids,
  );

  Future<List<DataRecord>> readCollection(String collection);

  Stream<List<DataRecord>> readCollectionChunks(
    String collection, {
    int chunkSize = BaseDataRepository.databaseExportChunkSize,
  });

  Future<List<String>> listCollections();

  Future<void> writeRecord(DataRecord record);

  Future<void> writeRecords(Iterable<DataRecord> records);

  Future<bool> deleteRecord(
    String collection,
    String id, {
    int? expectedVersion,
  });

  Future<int> deleteRecords(String collection, Iterable<String> ids);

  Future<bool> deleteCollection(String collection);

  /// Execute a filtered query over a collection, applying sort and pagination
  /// directly in the storage backend. Implementations should throw an
  /// [RpcDataError] when the requested filter or sort is not supported.
  Future<ListRecordsResponse> queryCollection(ListRecordsRequest request);

  /// Execute a search query against the backend, applying the provided filter
  /// and pagination options at the storage layer. Implementations should throw
  /// an [RpcDataError] when the request cannot be executed.
  Future<SearchRecordsResponse> searchCollection(SearchRecordsRequest request);

  Future<void> dispose();
}

abstract interface class ICollectionIndexStorageAdapter {
  Future<CollectionIndex> createCollectionIndex(
    CreateCollectionIndexRequest request,
  );

  Future<bool> deleteCollectionIndex(DeleteCollectionIndexRequest request);
}
