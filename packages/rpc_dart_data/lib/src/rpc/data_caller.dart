// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';
import 'package:rpc_dart/rpc_dart.dart';

import '../models.dart';
import 'data_contract.dart';

class DataServiceCaller extends RpcCallerContract
    implements IDataServiceContract {
  DataServiceCaller({
    required RpcCallerEndpoint endpoint,
    required RpcDataTransferMode transferMode,
  }) : super(
         IDataServiceContract.name,
         endpoint,
         dataTransferMode: transferMode,
       );

  Future<CreateRecordResponse> createRecord(
    CreateRecordRequest request, {
    RpcContext? context,
  }) {
    return callUnary(
      methodName: IDataServiceContract.createRecord,
      request: request,
      requestCodec: createRequestCodec,
      responseCodec: createResponseCodec,
      context: context,
    );
  }

  Future<GetRecordResponse> getRecord(
    GetRecordRequest request, {
    RpcContext? context,
  }) {
    return callUnary(
      methodName: IDataServiceContract.getRecord,
      request: request,
      requestCodec: getRequestCodec,
      responseCodec: getResponseCodec,
      context: context,
    );
  }

  Future<ListRecordsResponse> listRecords(
    ListRecordsRequest request, {
    RpcContext? context,
  }) {
    return callUnary(
      methodName: IDataServiceContract.listRecords,
      request: request,
      requestCodec: listRequestCodec,
      responseCodec: listResponseCodec,
      context: context,
    );
  }

  Future<ListCollectionsResponse> listCollections({RpcContext? context}) {
    return callUnary(
      methodName: IDataServiceContract.listCollections,
      request: const ListCollectionsRequest(),
      requestCodec: listCollectionsRequestCodec,
      responseCodec: listCollectionsResponseCodec,
      context: context,
    );
  }

  Future<UpdateRecordResponse> updateRecord(
    UpdateRecordRequest request, {
    RpcContext? context,
  }) {
    return callUnary(
      methodName: IDataServiceContract.updateRecord,
      request: request,
      requestCodec: updateRequestCodec,
      responseCodec: updateResponseCodec,
      context: context,
    );
  }

  Future<PatchRecordResponse> patchRecord(
    PatchRecordRequest request, {
    RpcContext? context,
  }) {
    return callUnary(
      methodName: IDataServiceContract.patchRecord,
      request: request,
      requestCodec: patchRequestCodec,
      responseCodec: patchResponseCodec,
      context: context,
    );
  }

  Future<DeleteRecordResponse> deleteRecord(
    DeleteRecordRequest request, {
    RpcContext? context,
  }) {
    return callUnary(
      methodName: IDataServiceContract.deleteRecord,
      request: request,
      requestCodec: deleteRequestCodec,
      responseCodec: deleteResponseCodec,
      context: context,
    );
  }

  Future<DeleteCollectionResponse> deleteCollection(
    DeleteCollectionRequest request, {
    RpcContext? context,
  }) {
    return callUnary(
      methodName: IDataServiceContract.deleteCollection,
      request: request,
      requestCodec: deleteCollectionRequestCodec,
      responseCodec: deleteCollectionResponseCodec,
      context: context,
    );
  }

  Future<ListSchemasResponse> listSchemas({RpcContext? context}) {
    return callUnary(
      methodName: IDataServiceContract.listSchemas,
      request: const ListSchemasRequest(),
      requestCodec: listSchemasRequestCodec,
      responseCodec: listSchemasResponseCodec,
      context: context,
    );
  }

  Future<GetSchemaResponse> getSchema(
    GetSchemaRequest request, {
    RpcContext? context,
  }) {
    return callUnary(
      methodName: IDataServiceContract.getSchema,
      request: request,
      requestCodec: getSchemaRequestCodec,
      responseCodec: getSchemaResponseCodec,
      context: context,
    );
  }

  Future<SetSchemaPolicyResponse> setSchemaPolicy(
    SetSchemaPolicyRequest request, {
    RpcContext? context,
  }) {
    return callUnary(
      methodName: IDataServiceContract.setSchemaPolicy,
      request: request,
      requestCodec: setSchemaPolicyRequestCodec,
      responseCodec: setSchemaPolicyResponseCodec,
      context: context,
    );
  }

  Future<BulkUpsertResponse> bulkUpsert(
    Stream<DataRecord> records, {
    RpcContext? context,
  }) {
    return callClientStream(
      methodName: IDataServiceContract.bulkUpsert,
      requests: records,
      requestCodec: recordCodec,
      responseCodec: bulkUpsertResponseCodec,
      context: context,
    );
  }

  Future<BulkDeleteResponse> bulkDelete(
    BulkDeleteRequest request, {
    RpcContext? context,
  }) {
    return callUnary(
      methodName: IDataServiceContract.bulkDelete,
      request: request,
      requestCodec: bulkDeleteRequestCodec,
      responseCodec: bulkDeleteResponseCodec,
      context: context,
    );
  }

  Future<ExportSnapshotResponse> exportSnapshot(
    ExportSnapshotRequest request, {
    RpcContext? context,
  }) {
    return callUnary(
      methodName: IDataServiceContract.exportSnapshot,
      request: request,
      requestCodec: exportRequestCodec,
      responseCodec: exportResponseCodec,
      context: context,
    );
  }

  Future<ExportDatabaseResponse> exportDatabase(
    ExportDatabaseRequest request, {
    RpcContext? context,
  }) {
    return callUnary(
      methodName: IDataServiceContract.exportDatabase,
      request: request,
      requestCodec: exportDatabaseRequestCodec,
      responseCodec: exportDatabaseResponseCodec,
      context: context,
    );
  }

  Future<ImportDatabaseResponse> importDatabase(
    ImportDatabaseRequest request, {
    RpcContext? context,
  }) {
    return callUnary(
      methodName: IDataServiceContract.importDatabase,
      request: request,
      requestCodec: importDatabaseRequestCodec,
      responseCodec: importDatabaseResponseCodec,
      context: context,
    );
  }

  Future<SearchRecordsResponse> searchRecords(
    SearchRecordsRequest request, {
    RpcContext? context,
  }) {
    return callUnary(
      methodName: IDataServiceContract.searchRecords,
      request: request,
      requestCodec: searchRequestCodec,
      responseCodec: searchResponseCodec,
      context: context,
    );
  }

  Future<CreateCollectionIndexResponse> createCollectionIndex(
    CreateCollectionIndexRequest request, {
    RpcContext? context,
  }) {
    return callUnary(
      methodName: IDataServiceContract.createCollectionIndex,
      request: request,
      requestCodec: createIndexRequestCodec,
      responseCodec: createIndexResponseCodec,
      context: context,
    );
  }

  Future<DeleteCollectionIndexResponse> deleteCollectionIndex(
    DeleteCollectionIndexRequest request, {
    RpcContext? context,
  }) {
    return callUnary(
      methodName: IDataServiceContract.deleteCollectionIndex,
      request: request,
      requestCodec: deleteIndexRequestCodec,
      responseCodec: deleteIndexResponseCodec,
      context: context,
    );
  }

  Stream<DataChangeEvent> watchChanges(
    WatchChangesRequest request, {
    RpcContext? context,
  }) {
    return callServerStream(
      methodName: IDataServiceContract.watchChanges,
      request: request,
      requestCodec: watchRequestCodec,
      responseCodec: changeEventCodec,
      context: context,
    );
  }

  /// Удобный helper для постраничного обхода коллекции.
  Future<List<DataRecord>> listAllRecords(
    String collection, {
    RecordFilter? filter,
    SortOrder? sort,
    RpcContext? context,
  }) async {
    final aggregated = <DataRecord>[];
    String? cursor;
    do {
      final response = await listRecords(
        ListRecordsRequest(
          collection: collection,
          filter: filter,
          sort: sort,
          options: QueryOptions(limit: 50, cursor: cursor),
        ),
        context: context,
      );
      aggregated.addAll(response.records);
      cursor = response.nextCursor;
    } while (cursor != null);
    return aggregated;
  }
}
