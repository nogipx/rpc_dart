import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_data/rpc_dart_data.dart';

/// Клиентская инкапсуляция. Хранит endpoint и caller и реализует интерфейс DataService.
class DataServiceClient implements IDataService {
  DataServiceClient(this._endpoint, this._caller);

  final RpcCallerEndpoint _endpoint;
  final DataServiceCaller _caller;

  @override
  Future<DataRecord> create({
    required String collection,
    required Map<String, dynamic> payload,
    String? id,
    RpcContext? context,
  }) async {
    final response = await _caller.createRecord(
      CreateRecordRequest(collection: collection, payload: payload, id: id),
      context: context,
    );
    return response.record;
  }

  @override
  Future<DataRecord?> get({
    required String collection,
    required String id,
    RpcContext? context,
  }) async {
    final response = await _caller.getRecord(
      GetRecordRequest(collection: collection, id: id),
      context: context,
    );
    return response.record;
  }

  @override
  Future<ListRecordsResponse> list({
    required String collection,
    RecordFilter? filter,
    SortOrder? sort,
    QueryOptions options = const QueryOptions(),
    RpcContext? context,
  }) {
    return _caller.listRecords(
      ListRecordsRequest(
        collection: collection,
        filter: filter,
        sort: sort,
        options: options,
      ),
      context: context,
    );
  }

  @override
  Future<List<String>> listCollections({RpcContext? context}) async {
    final response = await _caller.listCollections(context: context);
    return response.collections;
  }

  @override
  Future<List<DataRecord>> listAllRecords({
    required String collection,
    RecordFilter? filter,
    SortOrder? sort,
    RpcContext? context,
  }) {
    return _caller.listAllRecords(
      collection,
      filter: filter,
      sort: sort,
      context: context,
    );
  }

  @override
  Future<DataRecord> update({
    required String collection,
    required String id,
    required int expectedVersion,
    required Map<String, dynamic> payload,
    RpcContext? context,
  }) async {
    final response = await _caller.updateRecord(
      UpdateRecordRequest(
        collection: collection,
        id: id,
        expectedVersion: expectedVersion,
        payload: payload,
      ),
      context: context,
    );
    return response.record;
  }

  @override
  Future<DataRecord> patch({
    required String collection,
    required String id,
    required int expectedVersion,
    required RecordPatch patch,
    RpcContext? context,
  }) async {
    final response = await _caller.patchRecord(
      PatchRecordRequest(
        collection: collection,
        id: id,
        expectedVersion: expectedVersion,
        patch: patch,
      ),
      context: context,
    );
    return response.record;
  }

  @override
  Future<bool> delete({
    required String collection,
    required String id,
    int? expectedVersion,
    RpcContext? context,
  }) async {
    final response = await _caller.deleteRecord(
      DeleteRecordRequest(
        collection: collection,
        id: id,
        expectedVersion: expectedVersion,
      ),
      context: context,
    );
    return response.deleted;
  }

  @override
  Future<bool> deleteCollection({
    required String collection,
    RpcContext? context,
  }) async {
    final response = await _caller.deleteCollection(
      DeleteCollectionRequest(collection: collection),
      context: context,
    );
    return response.deleted;
  }

  @override
  Future<List<DataRecord>> bulkUpsert({
    required Iterable<DataRecord> records,
    RpcContext? context,
  }) {
    return bulkUpsertStream(
      records: Stream<DataRecord>.fromIterable(records),
      context: context,
    );
  }

  @override
  Future<List<DataRecord>> bulkUpsertStream({
    required Stream<DataRecord> records,
    RpcContext? context,
  }) async {
    final response = await _caller.bulkUpsert(records, context: context);
    return response.records;
  }

  @override
  Future<int> bulkDelete({
    required String collection,
    required List<String> ids,
    RpcContext? context,
  }) async {
    final response = await _caller.bulkDelete(
      BulkDeleteRequest(collection: collection, ids: ids),
      context: context,
    );
    return response.deletedCount;
  }

  @override
  Future<ExportSnapshotResponse> exportSnapshot({
    required String collection,
    RpcContext? context,
  }) {
    return _caller.exportSnapshot(
      ExportSnapshotRequest(collection: collection),
      context: context,
    );
  }

  @override
  Future<ExportDatabaseResponse> exportDatabase({
    bool includePayloadString = false,
    RpcContext? context,
  }) {
    return _caller.exportDatabase(
      ExportDatabaseRequest(includePayloadString: includePayloadString),
      context: context,
    );
  }

  @override
  Future<ImportDatabaseResponse> importDatabase({
    required String payload,
    bool replaceExisting = true,
    RpcContext? context,
  }) {
    return _caller.importDatabase(
      ImportDatabaseRequest(payload: payload, replaceExisting: replaceExisting),
      context: context,
    );
  }

  @override
  Future<SearchRecordsResponse> search({
    required String collection,
    required String query,
    RecordFilter? filter,
    QueryOptions options = const QueryOptions(),
    RpcContext? context,
  }) {
    return _caller.searchRecords(
      SearchRecordsRequest(
        collection: collection,
        query: query,
        filter: filter,
        options: options,
      ),
      context: context,
    );
  }

  @override
  Future<CollectionIndex> createCollectionIndex({
    required String collection,
    required String path,
    String? indexName,
    RpcContext? context,
  }) async {
    final response = await _caller.createCollectionIndex(
      CreateCollectionIndexRequest(
        collection: collection,
        path: path,
        indexName: indexName,
      ),
      context: context,
    );
    return response.index;
  }

  @override
  Future<bool> deleteCollectionIndex({
    required String collection,
    required String path,
    String? indexName,
    RpcContext? context,
  }) async {
    final response = await _caller.deleteCollectionIndex(
      DeleteCollectionIndexRequest(
        collection: collection,
        path: path,
        indexName: indexName,
      ),
      context: context,
    );
    return response.deleted;
  }

  @override
  Stream<DataChangeEvent> watchChanges({
    required String collection,
    String? cursor,
    RpcContext? context,
  }) {
    return _caller.watchChanges(
      WatchChangesRequest(collection: collection, cursor: cursor),
      context: context,
    );
  }

  @override
  Future<ListSchemasResponse> listSchemas({RpcContext? context}) {
    return _caller.listSchemas(context: context);
  }

  @override
  Future<GetSchemaResponse> getSchema({
    required String collection,
    RpcContext? context,
  }) {
    return _caller.getSchema(
      GetSchemaRequest(collection: collection),
      context: context,
    );
  }

  @override
  Future<SetSchemaPolicyResponse> setSchemaPolicy({
    required String collection,
    required bool enabled,
    required bool requireValidation,
    RpcContext? context,
  }) {
    return _caller.setSchemaPolicy(
      SetSchemaPolicyRequest(
        collection: collection,
        enabled: enabled,
        requireValidation: requireValidation,
      ),
      context: context,
    );
  }

  @override
  Future<void> close() => _endpoint.close();
}

/// Серверная обёртка: содержит endpoint, responder и репозиторий.
class DataServiceServer {
  DataServiceServer({
    required RpcResponderEndpoint endpoint,
    required DataServiceResponder responder,
    required IDataRepository repository,
  }) : _endpoint = endpoint,
       _responder = responder,
       _repository = repository;

  final RpcResponderEndpoint _endpoint;
  final DataServiceResponder _responder;
  final IDataRepository _repository;

  RpcResponderEndpoint get endpoint => _endpoint;
  DataServiceResponder get rawResponder => _responder;
  IDataRepository get repository => _repository;

  Future<void> start() async {
    _endpoint.registerServiceContract(_responder);
    _endpoint.start();
  }

  Future<void> close() async {
    await _endpoint.close();
    await _responder.dispose();
  }
}
