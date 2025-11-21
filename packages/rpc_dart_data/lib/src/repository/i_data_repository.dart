part of '_index.dart';

/// Абстракция репозитория данных.
abstract interface class IDataRepository {
  Future<DataRecord> create(CreateRecordRequest request);

  Future<DataRecord?> get(GetRecordRequest request);

  Future<ListRecordsResponse> list(ListRecordsRequest request);

  Future<DataRecord> update(UpdateRecordRequest request);

  Future<DataRecord> patch(PatchRecordRequest request);

  Future<bool> delete(DeleteRecordRequest request);

  Future<bool> deleteCollection(DeleteCollectionRequest request);

  Future<List<DataRecord>> bulkUpsert(BulkUpsertRequest request);

  Future<int> bulkDelete(BulkDeleteRequest request);

  Future<List<String>> listCollections();

  Future<ExportSnapshotResponse> exportSnapshot(ExportSnapshotRequest request);

  Future<ExportDatabaseResponse> exportDatabase(ExportDatabaseRequest request);

  Future<ImportDatabaseResponse> importDatabase(ImportDatabaseRequest request);

  Future<SearchRecordsResponse> search(SearchRecordsRequest request);

  Future<AggregateMetricsResponse> aggregate(AggregateMetricsRequest request);

  Stream<DataChangeEvent> watch(WatchChangesRequest request);

  Future<CollectionIndex> createCollectionIndex(
    CreateCollectionIndexRequest request,
  );

  Future<bool> deleteCollectionIndex(DeleteCollectionIndexRequest request);

  Stream<SyncChangeResponse> sync(Stream<SyncChangeRequest> requests);

  Future<void> dispose();
}
