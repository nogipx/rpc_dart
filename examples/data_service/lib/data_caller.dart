import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';

import 'data_contract.dart';
import 'models.dart';

class DataServiceCaller extends RpcCallerContract
    implements IDataServiceContract {
  DataServiceCaller(
    RpcCallerEndpoint endpoint, {
    RpcDataTransferMode mode = RpcDataTransferMode.codec,
  }) : super(
          IDataServiceContract.serviceName,
          endpoint,
          dataTransferMode: mode,
        );

  // В примере используется стандартный RpcCodec, который сериализует
  // IRpcSerializable-сообщения через встроенный CBOR кодек. При необходимости
  // его можно заменить на собственный codec, реализующий JSON или другой
  // формат, реализовав интерфейс [IRpcCodec].
  static const RpcCodec<CreateRecordRequest> _createRequestCodec =
      RpcCodec.withDecoder(CreateRecordRequest.fromJson);
  static const RpcCodec<CreateRecordResponse> _createResponseCodec =
      RpcCodec.withDecoder(CreateRecordResponse.fromJson);
  static const RpcCodec<GetRecordRequest> _getRequestCodec =
      RpcCodec.withDecoder(GetRecordRequest.fromJson);
  static const RpcCodec<GetRecordResponse> _getResponseCodec =
      RpcCodec.withDecoder(GetRecordResponse.fromJson);
  static const RpcCodec<ListRecordsRequest> _listRequestCodec =
      RpcCodec.withDecoder(ListRecordsRequest.fromJson);
  static const RpcCodec<ListRecordsResponse> _listResponseCodec =
      RpcCodec.withDecoder(ListRecordsResponse.fromJson);
  static const RpcCodec<UpdateRecordRequest> _updateRequestCodec =
      RpcCodec.withDecoder(UpdateRecordRequest.fromJson);
  static const RpcCodec<UpdateRecordResponse> _updateResponseCodec =
      RpcCodec.withDecoder(UpdateRecordResponse.fromJson);
  static const RpcCodec<PatchRecordRequest> _patchRequestCodec =
      RpcCodec.withDecoder(PatchRecordRequest.fromJson);
  static const RpcCodec<PatchRecordResponse> _patchResponseCodec =
      RpcCodec.withDecoder(PatchRecordResponse.fromJson);
  static const RpcCodec<DeleteRecordRequest> _deleteRequestCodec =
      RpcCodec.withDecoder(DeleteRecordRequest.fromJson);
  static const RpcCodec<DeleteRecordResponse> _deleteResponseCodec =
      RpcCodec.withDecoder(DeleteRecordResponse.fromJson);
  static const RpcCodec<DataRecord> _recordCodec =
      RpcCodec.withDecoder(DataRecord.fromJson);
  static const RpcCodec<BulkUpsertResponse> _bulkUpsertResponseCodec =
      RpcCodec.withDecoder(BulkUpsertResponse.fromJson);
  static const RpcCodec<BulkDeleteRequest> _bulkDeleteRequestCodec =
      RpcCodec.withDecoder(BulkDeleteRequest.fromJson);
  static const RpcCodec<BulkDeleteResponse> _bulkDeleteResponseCodec =
      RpcCodec.withDecoder(BulkDeleteResponse.fromJson);
  static const RpcCodec<ExportSnapshotRequest> _exportRequestCodec =
      RpcCodec.withDecoder(ExportSnapshotRequest.fromJson);
  static const RpcCodec<ExportSnapshotResponse> _exportResponseCodec =
      RpcCodec.withDecoder(ExportSnapshotResponse.fromJson);
  static const RpcCodec<SearchRecordsRequest> _searchRequestCodec =
      RpcCodec.withDecoder(SearchRecordsRequest.fromJson);
  static const RpcCodec<SearchRecordsResponse> _searchResponseCodec =
      RpcCodec.withDecoder(SearchRecordsResponse.fromJson);
  static const RpcCodec<AggregateMetricsRequest> _aggregateRequestCodec =
      RpcCodec.withDecoder(AggregateMetricsRequest.fromJson);
  static const RpcCodec<AggregateMetricsResponse> _aggregateResponseCodec =
      RpcCodec.withDecoder(AggregateMetricsResponse.fromJson);
  static const RpcCodec<WatchChangesRequest> _watchRequestCodec =
      RpcCodec.withDecoder(WatchChangesRequest.fromJson);
  static const RpcCodec<DataChangeEvent> _changeEventCodec =
      RpcCodec.withDecoder(DataChangeEvent.fromJson);
  static const RpcCodec<SyncChangeRequest> _syncRequestCodec =
      RpcCodec.withDecoder(SyncChangeRequest.fromJson);
  static const RpcCodec<SyncChangeResponse> _syncResponseCodec =
      RpcCodec.withDecoder(SyncChangeResponse.fromJson);

  Future<CreateRecordResponse> createRecord(
    CreateRecordRequest request, {
    RpcContext? context,
  }) {
    return callUnary(
      methodName: IDataServiceContract.createRecord,
      request: request,
      requestCodec: _createRequestCodec,
      responseCodec: _createResponseCodec,
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
      requestCodec: _getRequestCodec,
      responseCodec: _getResponseCodec,
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
      requestCodec: _listRequestCodec,
      responseCodec: _listResponseCodec,
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
      requestCodec: _updateRequestCodec,
      responseCodec: _updateResponseCodec,
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
      requestCodec: _patchRequestCodec,
      responseCodec: _patchResponseCodec,
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
      requestCodec: _deleteRequestCodec,
      responseCodec: _deleteResponseCodec,
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
      requestCodec: _recordCodec,
      responseCodec: _bulkUpsertResponseCodec,
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
      requestCodec: _bulkDeleteRequestCodec,
      responseCodec: _bulkDeleteResponseCodec,
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
      requestCodec: _exportRequestCodec,
      responseCodec: _exportResponseCodec,
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
      requestCodec: _searchRequestCodec,
      responseCodec: _searchResponseCodec,
      context: context,
    );
  }

  Future<AggregateMetricsResponse> aggregateMetrics(
    AggregateMetricsRequest request, {
    RpcContext? context,
  }) {
    return callUnary(
      methodName: IDataServiceContract.aggregateMetrics,
      request: request,
      requestCodec: _aggregateRequestCodec,
      responseCodec: _aggregateResponseCodec,
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
      requestCodec: _watchRequestCodec,
      responseCodec: _changeEventCodec,
      context: context,
    );
  }

  Stream<SyncChangeResponse> syncChanges(
    Stream<SyncChangeRequest> requests, {
    RpcContext? context,
  }) {
    return callBidirectionalStream(
      methodName: IDataServiceContract.syncChanges,
      requests: requests,
      requestCodec: _syncRequestCodec,
      responseCodec: _syncResponseCodec,
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

  /// Helper, который отправляет изменения и ждет первый ack.
  Future<SyncChangeResponse> pushAndAwaitAck(
    SyncChangeRequest request, {
    RpcContext? context,
  }) async {
    final controller = StreamController<SyncChangeRequest>();
    controller.add(request);
    await controller.close();
    return await syncChanges(controller.stream, context: context).first;
  }
}
