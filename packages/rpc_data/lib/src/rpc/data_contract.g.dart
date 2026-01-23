// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'data_contract.dart';

// **************************************************************************
// RpcDartGenerator
// **************************************************************************

// ignore_for_file: type=lint, unused_element

class DataServiceContractNames {
  const DataServiceContractNames._();
  static const service = 'DataService';
  static String instance(String suffix) => '\$service\_$suffix';
  static const createRecord = 'createRecord';
  static const getRecord = 'getRecord';
  static const listRecords = 'listRecords';
  static const listCollections = 'listCollections';
  static const updateRecord = 'updateRecord';
  static const patchRecord = 'patchRecord';
  static const deleteRecord = 'deleteRecord';
  static const deleteCollection = 'deleteCollection';
  static const bulkUpsert = 'bulkUpsert';
  static const bulkDelete = 'bulkDelete';
  static const exportSnapshot = 'exportSnapshot';
  static const exportDatabase = 'exportDatabase';
  static const importDatabase = 'importDatabase';
  static const searchRecords = 'searchRecords';
  static const createCollectionIndex = 'createCollectionIndex';
  static const deleteCollectionIndex = 'deleteCollectionIndex';
  static const watchChanges = 'watchChanges';
  static const listSchemas = 'listSchemas';
  static const getSchema = 'getSchema';
  static const setSchemaPolicy = 'setSchemaPolicy';
}

class DataServiceContractCaller extends RpcCallerContract
    implements IDataServiceContract {
  DataServiceContractCaller(
    RpcCallerEndpoint endpoint, {
    String? serviceNameOverride,
    RpcDataTransferMode dataTransferMode = RpcDataTransferMode.codec,
  }) : super(
         serviceNameOverride ?? DataServiceContractNames.service,
         endpoint,
         dataTransferMode: dataTransferMode,
       );

  @override
  Future<CreateRecordResponse> createRecord(
    CreateRecordRequest request, {
    RpcContext? context,
  }) {
    return callUnary<CreateRecordRequest, CreateRecordResponse>(
      methodName: DataServiceContractNames.createRecord,
      requestCodec: const RpcCodec<CreateRecordRequest>.withDecoder(
        CreateRecordRequest.fromJson,
      ),
      responseCodec: const RpcCodec<CreateRecordResponse>.withDecoder(
        CreateRecordResponse.fromJson,
      ),
      request: request,
      context: context,
    );
  }

  @override
  Future<GetRecordResponse> getRecord(
    GetRecordRequest request, {
    RpcContext? context,
  }) {
    return callUnary<GetRecordRequest, GetRecordResponse>(
      methodName: DataServiceContractNames.getRecord,
      requestCodec: const RpcCodec<GetRecordRequest>.withDecoder(
        GetRecordRequest.fromJson,
      ),
      responseCodec: const RpcCodec<GetRecordResponse>.withDecoder(
        GetRecordResponse.fromJson,
      ),
      request: request,
      context: context,
    );
  }

  @override
  Future<ListRecordsResponse> listRecords(
    ListRecordsRequest request, {
    RpcContext? context,
  }) {
    return callUnary<ListRecordsRequest, ListRecordsResponse>(
      methodName: DataServiceContractNames.listRecords,
      requestCodec: const RpcCodec<ListRecordsRequest>.withDecoder(
        ListRecordsRequest.fromJson,
      ),
      responseCodec: const RpcCodec<ListRecordsResponse>.withDecoder(
        ListRecordsResponse.fromJson,
      ),
      request: request,
      context: context,
    );
  }

  @override
  Future<ListCollectionsResponse> listCollections(
    ListCollectionsRequest request, {
    RpcContext? context,
  }) {
    return callUnary<ListCollectionsRequest, ListCollectionsResponse>(
      methodName: DataServiceContractNames.listCollections,
      requestCodec: const RpcCodec<ListCollectionsRequest>.withDecoder(
        ListCollectionsRequest.fromJson,
      ),
      responseCodec: const RpcCodec<ListCollectionsResponse>.withDecoder(
        ListCollectionsResponse.fromJson,
      ),
      request: request,
      context: context,
    );
  }

  @override
  Future<UpdateRecordResponse> updateRecord(
    UpdateRecordRequest request, {
    RpcContext? context,
  }) {
    return callUnary<UpdateRecordRequest, UpdateRecordResponse>(
      methodName: DataServiceContractNames.updateRecord,
      requestCodec: const RpcCodec<UpdateRecordRequest>.withDecoder(
        UpdateRecordRequest.fromJson,
      ),
      responseCodec: const RpcCodec<UpdateRecordResponse>.withDecoder(
        UpdateRecordResponse.fromJson,
      ),
      request: request,
      context: context,
    );
  }

  @override
  Future<PatchRecordResponse> patchRecord(
    PatchRecordRequest request, {
    RpcContext? context,
  }) {
    return callUnary<PatchRecordRequest, PatchRecordResponse>(
      methodName: DataServiceContractNames.patchRecord,
      requestCodec: const RpcCodec<PatchRecordRequest>.withDecoder(
        PatchRecordRequest.fromJson,
      ),
      responseCodec: const RpcCodec<PatchRecordResponse>.withDecoder(
        PatchRecordResponse.fromJson,
      ),
      request: request,
      context: context,
    );
  }

  @override
  Future<DeleteRecordResponse> deleteRecord(
    DeleteRecordRequest request, {
    RpcContext? context,
  }) {
    return callUnary<DeleteRecordRequest, DeleteRecordResponse>(
      methodName: DataServiceContractNames.deleteRecord,
      requestCodec: const RpcCodec<DeleteRecordRequest>.withDecoder(
        DeleteRecordRequest.fromJson,
      ),
      responseCodec: const RpcCodec<DeleteRecordResponse>.withDecoder(
        DeleteRecordResponse.fromJson,
      ),
      request: request,
      context: context,
    );
  }

  @override
  Future<DeleteCollectionResponse> deleteCollection(
    DeleteCollectionRequest request, {
    RpcContext? context,
  }) {
    return callUnary<DeleteCollectionRequest, DeleteCollectionResponse>(
      methodName: DataServiceContractNames.deleteCollection,
      requestCodec: const RpcCodec<DeleteCollectionRequest>.withDecoder(
        DeleteCollectionRequest.fromJson,
      ),
      responseCodec: const RpcCodec<DeleteCollectionResponse>.withDecoder(
        DeleteCollectionResponse.fromJson,
      ),
      request: request,
      context: context,
    );
  }

  @override
  Future<BulkUpsertResponse> bulkUpsert(
    Stream<DataRecord> requests, {
    RpcContext? context,
  }) {
    return callClientStream<DataRecord, BulkUpsertResponse>(
      methodName: DataServiceContractNames.bulkUpsert,
      requestCodec: const RpcCodec<DataRecord>.withDecoder(DataRecord.fromJson),
      responseCodec: const RpcCodec<BulkUpsertResponse>.withDecoder(
        BulkUpsertResponse.fromJson,
      ),
      requests: requests,
      context: context,
    );
  }

  @override
  Future<BulkDeleteResponse> bulkDelete(
    BulkDeleteRequest request, {
    RpcContext? context,
  }) {
    return callUnary<BulkDeleteRequest, BulkDeleteResponse>(
      methodName: DataServiceContractNames.bulkDelete,
      requestCodec: const RpcCodec<BulkDeleteRequest>.withDecoder(
        BulkDeleteRequest.fromJson,
      ),
      responseCodec: const RpcCodec<BulkDeleteResponse>.withDecoder(
        BulkDeleteResponse.fromJson,
      ),
      request: request,
      context: context,
    );
  }

  @override
  Future<ExportSnapshotResponse> exportSnapshot(
    ExportSnapshotRequest request, {
    RpcContext? context,
  }) {
    return callUnary<ExportSnapshotRequest, ExportSnapshotResponse>(
      methodName: DataServiceContractNames.exportSnapshot,
      requestCodec: const RpcCodec<ExportSnapshotRequest>.withDecoder(
        ExportSnapshotRequest.fromJson,
      ),
      responseCodec: const RpcCodec<ExportSnapshotResponse>.withDecoder(
        ExportSnapshotResponse.fromJson,
      ),
      request: request,
      context: context,
    );
  }

  @override
  Stream<DatabaseChunk> exportDatabase(
    ExportDatabaseRequest request, {
    RpcContext? context,
  }) {
    return callServerStream<ExportDatabaseRequest, DatabaseChunk>(
      methodName: DataServiceContractNames.exportDatabase,
      requestCodec: const RpcCodec<ExportDatabaseRequest>.withDecoder(
        ExportDatabaseRequest.fromJson,
      ),
      responseCodec: const RpcCodec<DatabaseChunk>.withDecoder(
        DatabaseChunk.fromJson,
      ),
      request: request,
      context: context,
    );
  }

  @override
  Stream<ImportProgress> importDatabase(
    Stream<DatabaseChunk> requests, {
    RpcContext? context,
  }) {
    return callBidirectionalStream<DatabaseChunk, ImportProgress>(
      methodName: DataServiceContractNames.importDatabase,
      requestCodec: const RpcCodec<DatabaseChunk>.withDecoder(
        DatabaseChunk.fromJson,
      ),
      responseCodec: const RpcCodec<ImportProgress>.withDecoder(
        ImportProgress.fromJson,
      ),
      requests: requests,
      context: context,
    );
  }

  @override
  Future<SearchRecordsResponse> searchRecords(
    SearchRecordsRequest request, {
    RpcContext? context,
  }) {
    return callUnary<SearchRecordsRequest, SearchRecordsResponse>(
      methodName: DataServiceContractNames.searchRecords,
      requestCodec: const RpcCodec<SearchRecordsRequest>.withDecoder(
        SearchRecordsRequest.fromJson,
      ),
      responseCodec: const RpcCodec<SearchRecordsResponse>.withDecoder(
        SearchRecordsResponse.fromJson,
      ),
      request: request,
      context: context,
    );
  }

  @override
  Future<CreateCollectionIndexResponse> createCollectionIndex(
    CreateCollectionIndexRequest request, {
    RpcContext? context,
  }) {
    return callUnary<
      CreateCollectionIndexRequest,
      CreateCollectionIndexResponse
    >(
      methodName: DataServiceContractNames.createCollectionIndex,
      requestCodec: const RpcCodec<CreateCollectionIndexRequest>.withDecoder(
        CreateCollectionIndexRequest.fromJson,
      ),
      responseCodec: const RpcCodec<CreateCollectionIndexResponse>.withDecoder(
        CreateCollectionIndexResponse.fromJson,
      ),
      request: request,
      context: context,
    );
  }

  @override
  Future<DeleteCollectionIndexResponse> deleteCollectionIndex(
    DeleteCollectionIndexRequest request, {
    RpcContext? context,
  }) {
    return callUnary<
      DeleteCollectionIndexRequest,
      DeleteCollectionIndexResponse
    >(
      methodName: DataServiceContractNames.deleteCollectionIndex,
      requestCodec: const RpcCodec<DeleteCollectionIndexRequest>.withDecoder(
        DeleteCollectionIndexRequest.fromJson,
      ),
      responseCodec: const RpcCodec<DeleteCollectionIndexResponse>.withDecoder(
        DeleteCollectionIndexResponse.fromJson,
      ),
      request: request,
      context: context,
    );
  }

  @override
  Stream<DataChangeEvent> watchChanges(
    WatchChangesRequest request, {
    RpcContext? context,
  }) {
    return callServerStream<WatchChangesRequest, DataChangeEvent>(
      methodName: DataServiceContractNames.watchChanges,
      requestCodec: const RpcCodec<WatchChangesRequest>.withDecoder(
        WatchChangesRequest.fromJson,
      ),
      responseCodec: const RpcCodec<DataChangeEvent>.withDecoder(
        DataChangeEvent.fromJson,
      ),
      request: request,
      context: context,
    );
  }

  @override
  Future<ListSchemasResponse> listSchemas(
    ListSchemasRequest request, {
    RpcContext? context,
  }) {
    return callUnary<ListSchemasRequest, ListSchemasResponse>(
      methodName: DataServiceContractNames.listSchemas,
      requestCodec: const RpcCodec<ListSchemasRequest>.withDecoder(
        ListSchemasRequest.fromJson,
      ),
      responseCodec: const RpcCodec<ListSchemasResponse>.withDecoder(
        ListSchemasResponse.fromJson,
      ),
      request: request,
      context: context,
    );
  }

  @override
  Future<GetSchemaResponse> getSchema(
    GetSchemaRequest request, {
    RpcContext? context,
  }) {
    return callUnary<GetSchemaRequest, GetSchemaResponse>(
      methodName: DataServiceContractNames.getSchema,
      requestCodec: const RpcCodec<GetSchemaRequest>.withDecoder(
        GetSchemaRequest.fromJson,
      ),
      responseCodec: const RpcCodec<GetSchemaResponse>.withDecoder(
        GetSchemaResponse.fromJson,
      ),
      request: request,
      context: context,
    );
  }

  @override
  Future<SetSchemaPolicyResponse> setSchemaPolicy(
    SetSchemaPolicyRequest request, {
    RpcContext? context,
  }) {
    return callUnary<SetSchemaPolicyRequest, SetSchemaPolicyResponse>(
      methodName: DataServiceContractNames.setSchemaPolicy,
      requestCodec: const RpcCodec<SetSchemaPolicyRequest>.withDecoder(
        SetSchemaPolicyRequest.fromJson,
      ),
      responseCodec: const RpcCodec<SetSchemaPolicyResponse>.withDecoder(
        SetSchemaPolicyResponse.fromJson,
      ),
      request: request,
      context: context,
    );
  }
}

abstract class DataServiceContractResponder extends RpcResponderContract
    implements IDataServiceContract {
  DataServiceContractResponder({
    String? serviceNameOverride,
    RpcDataTransferMode dataTransferMode = RpcDataTransferMode.codec,
  }) : super(
         serviceNameOverride ?? DataServiceContractNames.service,
         dataTransferMode: dataTransferMode,
       );

  @override
  void setup() {
    addUnaryMethod<CreateRecordRequest, CreateRecordResponse>(
      methodName: DataServiceContractNames.createRecord,
      handler: createRecord,
      description: 'Создание новой записи с проверкой прав и дедлайна',
      requestCodec: const RpcCodec<CreateRecordRequest>.withDecoder(
        CreateRecordRequest.fromJson,
      ),
      responseCodec: const RpcCodec<CreateRecordResponse>.withDecoder(
        CreateRecordResponse.fromJson,
      ),
    );
    addUnaryMethod<GetRecordRequest, GetRecordResponse>(
      methodName: DataServiceContractNames.getRecord,
      handler: getRecord,
      description: 'Получение записи по идентификатору',
      requestCodec: const RpcCodec<GetRecordRequest>.withDecoder(
        GetRecordRequest.fromJson,
      ),
      responseCodec: const RpcCodec<GetRecordResponse>.withDecoder(
        GetRecordResponse.fromJson,
      ),
    );
    addUnaryMethod<ListRecordsRequest, ListRecordsResponse>(
      methodName: DataServiceContractNames.listRecords,
      handler: listRecords,
      description: 'Постраничный список с фильтрацией и сортировкой',
      requestCodec: const RpcCodec<ListRecordsRequest>.withDecoder(
        ListRecordsRequest.fromJson,
      ),
      responseCodec: const RpcCodec<ListRecordsResponse>.withDecoder(
        ListRecordsResponse.fromJson,
      ),
    );
    addUnaryMethod<ListCollectionsRequest, ListCollectionsResponse>(
      methodName: DataServiceContractNames.listCollections,
      handler: listCollections,
      description: 'Список существующих коллекций',
      requestCodec: const RpcCodec<ListCollectionsRequest>.withDecoder(
        ListCollectionsRequest.fromJson,
      ),
      responseCodec: const RpcCodec<ListCollectionsResponse>.withDecoder(
        ListCollectionsResponse.fromJson,
      ),
    );
    addUnaryMethod<UpdateRecordRequest, UpdateRecordResponse>(
      methodName: DataServiceContractNames.updateRecord,
      handler: updateRecord,
      description: 'Полное обновление записи c оптимистической конкуренцией',
      requestCodec: const RpcCodec<UpdateRecordRequest>.withDecoder(
        UpdateRecordRequest.fromJson,
      ),
      responseCodec: const RpcCodec<UpdateRecordResponse>.withDecoder(
        UpdateRecordResponse.fromJson,
      ),
    );
    addUnaryMethod<PatchRecordRequest, PatchRecordResponse>(
      methodName: DataServiceContractNames.patchRecord,
      handler: patchRecord,
      description: 'Частичное обновление через RecordPatch',
      requestCodec: const RpcCodec<PatchRecordRequest>.withDecoder(
        PatchRecordRequest.fromJson,
      ),
      responseCodec: const RpcCodec<PatchRecordResponse>.withDecoder(
        PatchRecordResponse.fromJson,
      ),
    );
    addUnaryMethod<DeleteRecordRequest, DeleteRecordResponse>(
      methodName: DataServiceContractNames.deleteRecord,
      handler: deleteRecord,
      description: 'Удаление с проверкой версии',
      requestCodec: const RpcCodec<DeleteRecordRequest>.withDecoder(
        DeleteRecordRequest.fromJson,
      ),
      responseCodec: const RpcCodec<DeleteRecordResponse>.withDecoder(
        DeleteRecordResponse.fromJson,
      ),
    );
    addUnaryMethod<DeleteCollectionRequest, DeleteCollectionResponse>(
      methodName: DataServiceContractNames.deleteCollection,
      handler: deleteCollection,
      description: 'Удаление коллекции и всех записей',
      requestCodec: const RpcCodec<DeleteCollectionRequest>.withDecoder(
        DeleteCollectionRequest.fromJson,
      ),
      responseCodec: const RpcCodec<DeleteCollectionResponse>.withDecoder(
        DeleteCollectionResponse.fromJson,
      ),
    );
    addClientStreamMethod<DataRecord, BulkUpsertResponse>(
      methodName: DataServiceContractNames.bulkUpsert,
      handler: bulkUpsert,
      description: 'Пакетный upsert через клиентский стрим',
      requestCodec: const RpcCodec<DataRecord>.withDecoder(DataRecord.fromJson),
      responseCodec: const RpcCodec<BulkUpsertResponse>.withDecoder(
        BulkUpsertResponse.fromJson,
      ),
    );
    addUnaryMethod<BulkDeleteRequest, BulkDeleteResponse>(
      methodName: DataServiceContractNames.bulkDelete,
      handler: bulkDelete,
      description: 'Массовое удаление записей',
      requestCodec: const RpcCodec<BulkDeleteRequest>.withDecoder(
        BulkDeleteRequest.fromJson,
      ),
      responseCodec: const RpcCodec<BulkDeleteResponse>.withDecoder(
        BulkDeleteResponse.fromJson,
      ),
    );
    addUnaryMethod<ExportSnapshotRequest, ExportSnapshotResponse>(
      methodName: DataServiceContractNames.exportSnapshot,
      handler: exportSnapshot,
      description: 'Экспорт моментального снимка коллекции',
      requestCodec: const RpcCodec<ExportSnapshotRequest>.withDecoder(
        ExportSnapshotRequest.fromJson,
      ),
      responseCodec: const RpcCodec<ExportSnapshotResponse>.withDecoder(
        ExportSnapshotResponse.fromJson,
      ),
    );
    addServerStreamMethod<ExportDatabaseRequest, DatabaseChunk>(
      methodName: DataServiceContractNames.exportDatabase,
      handler: exportDatabase,
      description: 'Полный экспорт базы данных (стрим NDJSON чанков)',
      requestCodec: const RpcCodec<ExportDatabaseRequest>.withDecoder(
        ExportDatabaseRequest.fromJson,
      ),
      responseCodec: const RpcCodec<DatabaseChunk>.withDecoder(
        DatabaseChunk.fromJson,
      ),
    );
    addBidirectionalMethod<DatabaseChunk, ImportProgress>(
      methodName: DataServiceContractNames.importDatabase,
      handler: importDatabase,
      description:
          'Импорт полной базы данных из NDJSON чанков с ACK прогрессом',
      requestCodec: const RpcCodec<DatabaseChunk>.withDecoder(
        DatabaseChunk.fromJson,
      ),
      responseCodec: const RpcCodec<ImportProgress>.withDecoder(
        ImportProgress.fromJson,
      ),
    );
    addUnaryMethod<SearchRecordsRequest, SearchRecordsResponse>(
      methodName: DataServiceContractNames.searchRecords,
      handler: searchRecords,
      description: 'Полнотекстовый поиск по коллекции',
      requestCodec: const RpcCodec<SearchRecordsRequest>.withDecoder(
        SearchRecordsRequest.fromJson,
      ),
      responseCodec: const RpcCodec<SearchRecordsResponse>.withDecoder(
        SearchRecordsResponse.fromJson,
      ),
    );
    addUnaryMethod<CreateCollectionIndexRequest, CreateCollectionIndexResponse>(
      methodName: DataServiceContractNames.createCollectionIndex,
      handler: createCollectionIndex,
      description: 'Создание индексированного выражения для JSON-поля',
      requestCodec: const RpcCodec<CreateCollectionIndexRequest>.withDecoder(
        CreateCollectionIndexRequest.fromJson,
      ),
      responseCodec: const RpcCodec<CreateCollectionIndexResponse>.withDecoder(
        CreateCollectionIndexResponse.fromJson,
      ),
    );
    addUnaryMethod<DeleteCollectionIndexRequest, DeleteCollectionIndexResponse>(
      methodName: DataServiceContractNames.deleteCollectionIndex,
      handler: deleteCollectionIndex,
      description: 'Удаление индексированного выражения коллекции',
      requestCodec: const RpcCodec<DeleteCollectionIndexRequest>.withDecoder(
        DeleteCollectionIndexRequest.fromJson,
      ),
      responseCodec: const RpcCodec<DeleteCollectionIndexResponse>.withDecoder(
        DeleteCollectionIndexResponse.fromJson,
      ),
    );
    addServerStreamMethod<WatchChangesRequest, DataChangeEvent>(
      methodName: DataServiceContractNames.watchChanges,
      handler: watchChanges,
      description: 'Стрим изменений коллекции с курсором',
      requestCodec: const RpcCodec<WatchChangesRequest>.withDecoder(
        WatchChangesRequest.fromJson,
      ),
      responseCodec: const RpcCodec<DataChangeEvent>.withDecoder(
        DataChangeEvent.fromJson,
      ),
    );
    addUnaryMethod<ListSchemasRequest, ListSchemasResponse>(
      methodName: DataServiceContractNames.listSchemas,
      handler: listSchemas,
      description: 'Список активных схем коллекций',
      requestCodec: const RpcCodec<ListSchemasRequest>.withDecoder(
        ListSchemasRequest.fromJson,
      ),
      responseCodec: const RpcCodec<ListSchemasResponse>.withDecoder(
        ListSchemasResponse.fromJson,
      ),
    );
    addUnaryMethod<GetSchemaRequest, GetSchemaResponse>(
      methodName: DataServiceContractNames.getSchema,
      handler: getSchema,
      description: 'Получение схемы коллекции',
      requestCodec: const RpcCodec<GetSchemaRequest>.withDecoder(
        GetSchemaRequest.fromJson,
      ),
      responseCodec: const RpcCodec<GetSchemaResponse>.withDecoder(
        GetSchemaResponse.fromJson,
      ),
    );
    addUnaryMethod<SetSchemaPolicyRequest, SetSchemaPolicyResponse>(
      methodName: DataServiceContractNames.setSchemaPolicy,
      handler: setSchemaPolicy,
      description: 'Установка политики схемы коллекции',
      requestCodec: const RpcCodec<SetSchemaPolicyRequest>.withDecoder(
        SetSchemaPolicyRequest.fromJson,
      ),
      responseCodec: const RpcCodec<SetSchemaPolicyResponse>.withDecoder(
        SetSchemaPolicyResponse.fromJson,
      ),
    );
  }
}
