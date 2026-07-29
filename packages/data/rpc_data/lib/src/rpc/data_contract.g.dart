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
  static String instance(String suffix) => '$service\_$suffix';
  static const createRecord = 'createRecord';
  static const getRecord = 'getRecord';
  static const getRecords = 'getRecords';
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

class DataServiceContractCodecs {
  const DataServiceContractCodecs._();
  static const codecBulkDeleteRequest = RpcCodec<BulkDeleteRequest>.withDecoder(
    BulkDeleteRequest.fromJson,
  );
  static const codecBulkDeleteResponse =
      RpcCodec<BulkDeleteResponse>.withDecoder(BulkDeleteResponse.fromJson);
  static const codecBulkUpsertResponse =
      RpcCodec<BulkUpsertResponse>.withDecoder(BulkUpsertResponse.fromJson);
  static const codecCreateCollectionIndexRequest =
      RpcCodec<CreateCollectionIndexRequest>.withDecoder(
        CreateCollectionIndexRequest.fromJson,
      );
  static const codecCreateCollectionIndexResponse =
      RpcCodec<CreateCollectionIndexResponse>.withDecoder(
        CreateCollectionIndexResponse.fromJson,
      );
  static const codecCreateRecordRequest =
      RpcCodec<CreateRecordRequest>.withDecoder(CreateRecordRequest.fromJson);
  static const codecCreateRecordResponse =
      RpcCodec<CreateRecordResponse>.withDecoder(CreateRecordResponse.fromJson);
  static const codecDataChangeEvent = RpcCodec<DataChangeEvent>.withDecoder(
    DataChangeEvent.fromJson,
  );
  static const codecDataRecord = RpcCodec<DataRecord>.withDecoder(
    DataRecord.fromJson,
  );
  static const codecDatabaseChunk = RpcCodec<DatabaseChunk>.withDecoder(
    DatabaseChunk.fromJson,
  );
  static const codecDeleteCollectionIndexRequest =
      RpcCodec<DeleteCollectionIndexRequest>.withDecoder(
        DeleteCollectionIndexRequest.fromJson,
      );
  static const codecDeleteCollectionIndexResponse =
      RpcCodec<DeleteCollectionIndexResponse>.withDecoder(
        DeleteCollectionIndexResponse.fromJson,
      );
  static const codecDeleteCollectionRequest =
      RpcCodec<DeleteCollectionRequest>.withDecoder(
        DeleteCollectionRequest.fromJson,
      );
  static const codecDeleteCollectionResponse =
      RpcCodec<DeleteCollectionResponse>.withDecoder(
        DeleteCollectionResponse.fromJson,
      );
  static const codecDeleteRecordRequest =
      RpcCodec<DeleteRecordRequest>.withDecoder(DeleteRecordRequest.fromJson);
  static const codecDeleteRecordResponse =
      RpcCodec<DeleteRecordResponse>.withDecoder(DeleteRecordResponse.fromJson);
  static const codecExportDatabaseRequest =
      RpcCodec<ExportDatabaseRequest>.withDecoder(
        ExportDatabaseRequest.fromJson,
      );
  static const codecExportSnapshotRequest =
      RpcCodec<ExportSnapshotRequest>.withDecoder(
        ExportSnapshotRequest.fromJson,
      );
  static const codecExportSnapshotResponse =
      RpcCodec<ExportSnapshotResponse>.withDecoder(
        ExportSnapshotResponse.fromJson,
      );
  static const codecGetRecordRequest = RpcCodec<GetRecordRequest>.withDecoder(
    GetRecordRequest.fromJson,
  );
  static const codecGetRecordResponse = RpcCodec<GetRecordResponse>.withDecoder(
    GetRecordResponse.fromJson,
  );
  static const codecGetRecordsRequest = RpcCodec<GetRecordsRequest>.withDecoder(
    GetRecordsRequest.fromJson,
  );
  static const codecGetRecordsResponse =
      RpcCodec<GetRecordsResponse>.withDecoder(GetRecordsResponse.fromJson);
  static const codecGetSchemaRequest = RpcCodec<GetSchemaRequest>.withDecoder(
    GetSchemaRequest.fromJson,
  );
  static const codecGetSchemaResponse = RpcCodec<GetSchemaResponse>.withDecoder(
    GetSchemaResponse.fromJson,
  );
  static const codecImportProgress = RpcCodec<ImportProgress>.withDecoder(
    ImportProgress.fromJson,
  );
  static const codecListCollectionsRequest =
      RpcCodec<ListCollectionsRequest>.withDecoder(
        ListCollectionsRequest.fromJson,
      );
  static const codecListCollectionsResponse =
      RpcCodec<ListCollectionsResponse>.withDecoder(
        ListCollectionsResponse.fromJson,
      );
  static const codecListRecordsRequest =
      RpcCodec<ListRecordsRequest>.withDecoder(ListRecordsRequest.fromJson);
  static const codecListRecordsResponse =
      RpcCodec<ListRecordsResponse>.withDecoder(ListRecordsResponse.fromJson);
  static const codecListSchemasRequest =
      RpcCodec<ListSchemasRequest>.withDecoder(ListSchemasRequest.fromJson);
  static const codecListSchemasResponse =
      RpcCodec<ListSchemasResponse>.withDecoder(ListSchemasResponse.fromJson);
  static const codecPatchRecordRequest =
      RpcCodec<PatchRecordRequest>.withDecoder(PatchRecordRequest.fromJson);
  static const codecPatchRecordResponse =
      RpcCodec<PatchRecordResponse>.withDecoder(PatchRecordResponse.fromJson);
  static const codecSearchRecordsRequest =
      RpcCodec<SearchRecordsRequest>.withDecoder(SearchRecordsRequest.fromJson);
  static const codecSearchRecordsResponse =
      RpcCodec<SearchRecordsResponse>.withDecoder(
        SearchRecordsResponse.fromJson,
      );
  static const codecSetSchemaPolicyRequest =
      RpcCodec<SetSchemaPolicyRequest>.withDecoder(
        SetSchemaPolicyRequest.fromJson,
      );
  static const codecSetSchemaPolicyResponse =
      RpcCodec<SetSchemaPolicyResponse>.withDecoder(
        SetSchemaPolicyResponse.fromJson,
      );
  static const codecUpdateRecordRequest =
      RpcCodec<UpdateRecordRequest>.withDecoder(UpdateRecordRequest.fromJson);
  static const codecUpdateRecordResponse =
      RpcCodec<UpdateRecordResponse>.withDecoder(UpdateRecordResponse.fromJson);
  static const codecWatchChangesRequest =
      RpcCodec<WatchChangesRequest>.withDecoder(WatchChangesRequest.fromJson);
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
      requestCodec: DataServiceContractCodecs.codecCreateRecordRequest,
      responseCodec: DataServiceContractCodecs.codecCreateRecordResponse,
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
      requestCodec: DataServiceContractCodecs.codecGetRecordRequest,
      responseCodec: DataServiceContractCodecs.codecGetRecordResponse,
      request: request,
      context: context,
    );
  }

  @override
  Future<GetRecordsResponse> getRecords(
    GetRecordsRequest request, {
    RpcContext? context,
  }) {
    return callUnary<GetRecordsRequest, GetRecordsResponse>(
      methodName: DataServiceContractNames.getRecords,
      requestCodec: DataServiceContractCodecs.codecGetRecordsRequest,
      responseCodec: DataServiceContractCodecs.codecGetRecordsResponse,
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
      requestCodec: DataServiceContractCodecs.codecListRecordsRequest,
      responseCodec: DataServiceContractCodecs.codecListRecordsResponse,
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
      requestCodec: DataServiceContractCodecs.codecListCollectionsRequest,
      responseCodec: DataServiceContractCodecs.codecListCollectionsResponse,
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
      requestCodec: DataServiceContractCodecs.codecUpdateRecordRequest,
      responseCodec: DataServiceContractCodecs.codecUpdateRecordResponse,
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
      requestCodec: DataServiceContractCodecs.codecPatchRecordRequest,
      responseCodec: DataServiceContractCodecs.codecPatchRecordResponse,
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
      requestCodec: DataServiceContractCodecs.codecDeleteRecordRequest,
      responseCodec: DataServiceContractCodecs.codecDeleteRecordResponse,
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
      requestCodec: DataServiceContractCodecs.codecDeleteCollectionRequest,
      responseCodec: DataServiceContractCodecs.codecDeleteCollectionResponse,
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
      requestCodec: DataServiceContractCodecs.codecDataRecord,
      responseCodec: DataServiceContractCodecs.codecBulkUpsertResponse,
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
      requestCodec: DataServiceContractCodecs.codecBulkDeleteRequest,
      responseCodec: DataServiceContractCodecs.codecBulkDeleteResponse,
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
      requestCodec: DataServiceContractCodecs.codecExportSnapshotRequest,
      responseCodec: DataServiceContractCodecs.codecExportSnapshotResponse,
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
      requestCodec: DataServiceContractCodecs.codecExportDatabaseRequest,
      responseCodec: DataServiceContractCodecs.codecDatabaseChunk,
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
      requestCodec: DataServiceContractCodecs.codecDatabaseChunk,
      responseCodec: DataServiceContractCodecs.codecImportProgress,
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
      requestCodec: DataServiceContractCodecs.codecSearchRecordsRequest,
      responseCodec: DataServiceContractCodecs.codecSearchRecordsResponse,
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
      requestCodec: DataServiceContractCodecs.codecCreateCollectionIndexRequest,
      responseCodec:
          DataServiceContractCodecs.codecCreateCollectionIndexResponse,
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
      requestCodec: DataServiceContractCodecs.codecDeleteCollectionIndexRequest,
      responseCodec:
          DataServiceContractCodecs.codecDeleteCollectionIndexResponse,
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
      requestCodec: DataServiceContractCodecs.codecWatchChangesRequest,
      responseCodec: DataServiceContractCodecs.codecDataChangeEvent,
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
      requestCodec: DataServiceContractCodecs.codecListSchemasRequest,
      responseCodec: DataServiceContractCodecs.codecListSchemasResponse,
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
      requestCodec: DataServiceContractCodecs.codecGetSchemaRequest,
      responseCodec: DataServiceContractCodecs.codecGetSchemaResponse,
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
      requestCodec: DataServiceContractCodecs.codecSetSchemaPolicyRequest,
      responseCodec: DataServiceContractCodecs.codecSetSchemaPolicyResponse,
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
      requestCodec: DataServiceContractCodecs.codecCreateRecordRequest,
      responseCodec: DataServiceContractCodecs.codecCreateRecordResponse,
    );
    addUnaryMethod<GetRecordRequest, GetRecordResponse>(
      methodName: DataServiceContractNames.getRecord,
      handler: getRecord,
      description: 'Получение записи по идентификатору',
      requestCodec: DataServiceContractCodecs.codecGetRecordRequest,
      responseCodec: DataServiceContractCodecs.codecGetRecordResponse,
    );
    addUnaryMethod<GetRecordsRequest, GetRecordsResponse>(
      methodName: DataServiceContractNames.getRecords,
      handler: getRecords,
      description: 'Пакетное чтение записей коллекции по идентификаторам',
      requestCodec: DataServiceContractCodecs.codecGetRecordsRequest,
      responseCodec: DataServiceContractCodecs.codecGetRecordsResponse,
    );
    addUnaryMethod<ListRecordsRequest, ListRecordsResponse>(
      methodName: DataServiceContractNames.listRecords,
      handler: listRecords,
      description: 'Постраничный список с фильтрацией и сортировкой',
      requestCodec: DataServiceContractCodecs.codecListRecordsRequest,
      responseCodec: DataServiceContractCodecs.codecListRecordsResponse,
    );
    addUnaryMethod<ListCollectionsRequest, ListCollectionsResponse>(
      methodName: DataServiceContractNames.listCollections,
      handler: listCollections,
      description: 'Список существующих коллекций',
      requestCodec: DataServiceContractCodecs.codecListCollectionsRequest,
      responseCodec: DataServiceContractCodecs.codecListCollectionsResponse,
    );
    addUnaryMethod<UpdateRecordRequest, UpdateRecordResponse>(
      methodName: DataServiceContractNames.updateRecord,
      handler: updateRecord,
      description: 'Полное обновление записи c оптимистической конкуренцией',
      requestCodec: DataServiceContractCodecs.codecUpdateRecordRequest,
      responseCodec: DataServiceContractCodecs.codecUpdateRecordResponse,
    );
    addUnaryMethod<PatchRecordRequest, PatchRecordResponse>(
      methodName: DataServiceContractNames.patchRecord,
      handler: patchRecord,
      description: 'Частичное обновление через RecordPatch',
      requestCodec: DataServiceContractCodecs.codecPatchRecordRequest,
      responseCodec: DataServiceContractCodecs.codecPatchRecordResponse,
    );
    addUnaryMethod<DeleteRecordRequest, DeleteRecordResponse>(
      methodName: DataServiceContractNames.deleteRecord,
      handler: deleteRecord,
      description: 'Удаление с проверкой версии',
      requestCodec: DataServiceContractCodecs.codecDeleteRecordRequest,
      responseCodec: DataServiceContractCodecs.codecDeleteRecordResponse,
    );
    addUnaryMethod<DeleteCollectionRequest, DeleteCollectionResponse>(
      methodName: DataServiceContractNames.deleteCollection,
      handler: deleteCollection,
      description: 'Удаление коллекции и всех записей',
      requestCodec: DataServiceContractCodecs.codecDeleteCollectionRequest,
      responseCodec: DataServiceContractCodecs.codecDeleteCollectionResponse,
    );
    addClientStreamMethod<DataRecord, BulkUpsertResponse>(
      methodName: DataServiceContractNames.bulkUpsert,
      handler: bulkUpsert,
      description: 'Пакетный upsert через клиентский стрим',
      requestCodec: DataServiceContractCodecs.codecDataRecord,
      responseCodec: DataServiceContractCodecs.codecBulkUpsertResponse,
    );
    addUnaryMethod<BulkDeleteRequest, BulkDeleteResponse>(
      methodName: DataServiceContractNames.bulkDelete,
      handler: bulkDelete,
      description: 'Массовое удаление записей',
      requestCodec: DataServiceContractCodecs.codecBulkDeleteRequest,
      responseCodec: DataServiceContractCodecs.codecBulkDeleteResponse,
    );
    addUnaryMethod<ExportSnapshotRequest, ExportSnapshotResponse>(
      methodName: DataServiceContractNames.exportSnapshot,
      handler: exportSnapshot,
      description: 'Экспорт моментального снимка коллекции',
      requestCodec: DataServiceContractCodecs.codecExportSnapshotRequest,
      responseCodec: DataServiceContractCodecs.codecExportSnapshotResponse,
    );
    addServerStreamMethod<ExportDatabaseRequest, DatabaseChunk>(
      methodName: DataServiceContractNames.exportDatabase,
      handler: exportDatabase,
      description: 'Полный экспорт базы данных (стрим NDJSON чанков)',
      requestCodec: DataServiceContractCodecs.codecExportDatabaseRequest,
      responseCodec: DataServiceContractCodecs.codecDatabaseChunk,
    );
    addBidirectionalMethod<DatabaseChunk, ImportProgress>(
      methodName: DataServiceContractNames.importDatabase,
      handler: importDatabase,
      description:
          'Импорт полной базы данных из NDJSON чанков с ACK прогрессом',
      requestCodec: DataServiceContractCodecs.codecDatabaseChunk,
      responseCodec: DataServiceContractCodecs.codecImportProgress,
    );
    addUnaryMethod<SearchRecordsRequest, SearchRecordsResponse>(
      methodName: DataServiceContractNames.searchRecords,
      handler: searchRecords,
      description: 'Полнотекстовый поиск по коллекции',
      requestCodec: DataServiceContractCodecs.codecSearchRecordsRequest,
      responseCodec: DataServiceContractCodecs.codecSearchRecordsResponse,
    );
    addUnaryMethod<CreateCollectionIndexRequest, CreateCollectionIndexResponse>(
      methodName: DataServiceContractNames.createCollectionIndex,
      handler: createCollectionIndex,
      description: 'Создание индексированного выражения для JSON-поля',
      requestCodec: DataServiceContractCodecs.codecCreateCollectionIndexRequest,
      responseCodec:
          DataServiceContractCodecs.codecCreateCollectionIndexResponse,
    );
    addUnaryMethod<DeleteCollectionIndexRequest, DeleteCollectionIndexResponse>(
      methodName: DataServiceContractNames.deleteCollectionIndex,
      handler: deleteCollectionIndex,
      description: 'Удаление индексированного выражения коллекции',
      requestCodec: DataServiceContractCodecs.codecDeleteCollectionIndexRequest,
      responseCodec:
          DataServiceContractCodecs.codecDeleteCollectionIndexResponse,
    );
    addServerStreamMethod<WatchChangesRequest, DataChangeEvent>(
      methodName: DataServiceContractNames.watchChanges,
      handler: watchChanges,
      description: 'Стрим изменений коллекции с курсором',
      requestCodec: DataServiceContractCodecs.codecWatchChangesRequest,
      responseCodec: DataServiceContractCodecs.codecDataChangeEvent,
    );
    addUnaryMethod<ListSchemasRequest, ListSchemasResponse>(
      methodName: DataServiceContractNames.listSchemas,
      handler: listSchemas,
      description: 'Список активных схем коллекций',
      requestCodec: DataServiceContractCodecs.codecListSchemasRequest,
      responseCodec: DataServiceContractCodecs.codecListSchemasResponse,
    );
    addUnaryMethod<GetSchemaRequest, GetSchemaResponse>(
      methodName: DataServiceContractNames.getSchema,
      handler: getSchema,
      description: 'Получение схемы коллекции',
      requestCodec: DataServiceContractCodecs.codecGetSchemaRequest,
      responseCodec: DataServiceContractCodecs.codecGetSchemaResponse,
    );
    addUnaryMethod<SetSchemaPolicyRequest, SetSchemaPolicyResponse>(
      methodName: DataServiceContractNames.setSchemaPolicy,
      handler: setSchemaPolicy,
      description: 'Установка политики схемы коллекции',
      requestCodec: DataServiceContractCodecs.codecSetSchemaPolicyRequest,
      responseCodec: DataServiceContractCodecs.codecSetSchemaPolicyResponse,
    );
  }
}
