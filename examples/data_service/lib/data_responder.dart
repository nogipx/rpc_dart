import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';

import 'data_contract.dart';
import 'data_repository.dart';
import 'models.dart';

class DataServiceResponder extends RpcResponderContract
    implements IDataServiceContract {
  DataServiceResponder({required DataRepository repository})
      : _repository = repository,
        super(
          IDataServiceContract.serviceName,
          dataTransferMode: RpcDataTransferMode.codec,
        );

  final DataRepository _repository;

  // Стандартный RpcCodec использует CBOR сериализацию. Для сетевой
  // совместимости его можно заменить на собственную реализацию IRpcCodec,
  // если требуется JSON или другой формат.
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
  static const RpcCodec<BulkDeleteRequest> _bulkDeleteRequestCodec =
      RpcCodec.withDecoder(BulkDeleteRequest.fromJson);
  static const RpcCodec<BulkDeleteResponse> _bulkDeleteResponseCodec =
      RpcCodec.withDecoder(BulkDeleteResponse.fromJson);
  static const RpcCodec<DataRecord> _recordCodec =
      RpcCodec.withDecoder(DataRecord.fromJson);
  static const RpcCodec<BulkUpsertResponse> _bulkUpsertResponseCodec =
      RpcCodec.withDecoder(BulkUpsertResponse.fromJson);
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

  @override
  void setup() {
    addUnaryMethod<CreateRecordRequest, CreateRecordResponse>(
      methodName: IDataServiceContract.createRecord,
      handler: _handleCreate,
      requestCodec: _createRequestCodec,
      responseCodec: _createResponseCodec,
      description: 'Создание новой записи с проверкой прав и дедлайна',
    );

    addUnaryMethod<GetRecordRequest, GetRecordResponse>(
      methodName: IDataServiceContract.getRecord,
      handler: _handleGet,
      requestCodec: _getRequestCodec,
      responseCodec: _getResponseCodec,
      description: 'Получение записи по идентификатору',
    );

    addUnaryMethod<ListRecordsRequest, ListRecordsResponse>(
      methodName: IDataServiceContract.listRecords,
      handler: _handleList,
      requestCodec: _listRequestCodec,
      responseCodec: _listResponseCodec,
      description: 'Постраничный список с фильтрацией и сортировкой',
    );

    addUnaryMethod<UpdateRecordRequest, UpdateRecordResponse>(
      methodName: IDataServiceContract.updateRecord,
      handler: _handleUpdate,
      requestCodec: _updateRequestCodec,
      responseCodec: _updateResponseCodec,
      description: 'Полное обновление записи c оптимистической конкуренцией',
    );

    addUnaryMethod<PatchRecordRequest, PatchRecordResponse>(
      methodName: IDataServiceContract.patchRecord,
      handler: _handlePatch,
      requestCodec: _patchRequestCodec,
      responseCodec: _patchResponseCodec,
      description: 'Частичное обновление через RecordPatch',
    );

    addUnaryMethod<DeleteRecordRequest, DeleteRecordResponse>(
      methodName: IDataServiceContract.deleteRecord,
      handler: _handleDelete,
      requestCodec: _deleteRequestCodec,
      responseCodec: _deleteResponseCodec,
      description: 'Удаление с проверкой версии',
    );

    addClientStreamMethod<DataRecord, BulkUpsertResponse>(
      methodName: IDataServiceContract.bulkUpsert,
      handler: _handleBulkUpsertStream,
      requestCodec: _recordCodec,
      responseCodec: _bulkUpsertResponseCodec,
      description: 'Пакетный upsert через клиентский стрим',
    );

    addUnaryMethod<BulkDeleteRequest, BulkDeleteResponse>(
      methodName: IDataServiceContract.bulkDelete,
      handler: _handleBulkDelete,
      requestCodec: _bulkDeleteRequestCodec,
      responseCodec: _bulkDeleteResponseCodec,
      description: 'Массовое удаление записей',
    );

    addUnaryMethod<ExportSnapshotRequest, ExportSnapshotResponse>(
      methodName: IDataServiceContract.exportSnapshot,
      handler: _handleExport,
      requestCodec: _exportRequestCodec,
      responseCodec: _exportResponseCodec,
      description: 'Экспорт моментального снимка коллекции',
    );

    addUnaryMethod<SearchRecordsRequest, SearchRecordsResponse>(
      methodName: IDataServiceContract.searchRecords,
      handler: _handleSearch,
      requestCodec: _searchRequestCodec,
      responseCodec: _searchResponseCodec,
      description: 'Полнотекстовый поиск по коллекции',
    );

    addUnaryMethod<AggregateMetricsRequest, AggregateMetricsResponse>(
      methodName: IDataServiceContract.aggregateMetrics,
      handler: _handleAggregate,
      requestCodec: _aggregateRequestCodec,
      responseCodec: _aggregateResponseCodec,
      description: 'Агрегирование по полям',
    );

    addServerStreamMethod<WatchChangesRequest, DataChangeEvent>(
      methodName: IDataServiceContract.watchChanges,
      handler: _handleWatch,
      requestCodec: _watchRequestCodec,
      responseCodec: _changeEventCodec,
      description: 'Стрим изменений коллекции с курсором',
    );

    addBidirectionalMethod<SyncChangeRequest, SyncChangeResponse>(
      methodName: IDataServiceContract.syncChanges,
      handler: _handleSync,
      requestCodec: _syncRequestCodec,
      responseCodec: _syncResponseCodec,
      description: 'Двунаправленная синхронизация офлайн клиента (command queue)',
    );
  }

  Future<CreateRecordResponse> _handleCreate(
    CreateRecordRequest request, {
    RpcContext? context,
  }) async {
    final tenant = _resolveTenant(context);
    final record = await _runSafely(
      context,
      () => _repository.create(tenant, request),
    );
    return CreateRecordResponse(record: record);
  }

  Future<GetRecordResponse> _handleGet(
    GetRecordRequest request, {
    RpcContext? context,
  }) async {
    final tenant = _resolveTenant(context);
    final record = await _runSafely(
      context,
      () => _repository.get(tenant, request),
    );
    return GetRecordResponse(record: record);
  }

  Future<ListRecordsResponse> _handleList(
    ListRecordsRequest request, {
    RpcContext? context,
  }) async {
    final tenant = _resolveTenant(context);
    return _runSafely(
      context,
      () => _repository.list(tenant, request),
    );
  }

  Future<UpdateRecordResponse> _handleUpdate(
    UpdateRecordRequest request, {
    RpcContext? context,
  }) async {
    final tenant = _resolveTenant(context);
    final record = await _runSafely(
      context,
      () => _repository.update(tenant, request),
    );
    return UpdateRecordResponse(record: record);
  }

  Future<PatchRecordResponse> _handlePatch(
    PatchRecordRequest request, {
    RpcContext? context,
  }) async {
    final tenant = _resolveTenant(context);
    final record = await _runSafely(
      context,
      () => _repository.patch(tenant, request),
    );
    return PatchRecordResponse(record: record);
  }

  Future<DeleteRecordResponse> _handleDelete(
    DeleteRecordRequest request, {
    RpcContext? context,
  }) async {
    final tenant = _resolveTenant(context);
    final deleted = await _runSafely(
      context,
      () => _repository.delete(tenant, request),
    );
    return DeleteRecordResponse(deleted: deleted);
  }

  Future<BulkUpsertResponse> _handleBulkUpsertStream(
    Stream<DataRecord> records, {
    RpcContext? context,
  }) async {
    final tenant = _resolveTenant(context);
    final collected = await records.toList();
    if (collected.isEmpty) {
      return const BulkUpsertResponse(records: []);
    }
    final saved = await _runSafely(
      context,
      () => _repository.bulkUpsert(
        tenant,
        BulkUpsertRequest(records: collected),
      ),
    );
    return BulkUpsertResponse(records: saved);
  }

  Future<BulkDeleteResponse> _handleBulkDelete(
    BulkDeleteRequest request, {
    RpcContext? context,
  }) async {
    final tenant = _resolveTenant(context);
    final deleted = await _runSafely(
      context,
      () => _repository.bulkDelete(tenant, request),
    );
    return BulkDeleteResponse(deletedCount: deleted);
  }

  Future<ExportSnapshotResponse> _handleExport(
    ExportSnapshotRequest request, {
    RpcContext? context,
  }) async {
    final tenant = _resolveTenant(context);
    return _runSafely(
      context,
      () => _repository.exportSnapshot(tenant, request),
    );
  }

  Future<SearchRecordsResponse> _handleSearch(
    SearchRecordsRequest request, {
    RpcContext? context,
  }) async {
    final tenant = _resolveTenant(context);
    return _runSafely(
      context,
      () => _repository.search(tenant, request),
    );
  }

  Future<AggregateMetricsResponse> _handleAggregate(
    AggregateMetricsRequest request, {
    RpcContext? context,
  }) async {
    final tenant = _resolveTenant(context);
    return _runSafely(
      context,
      () => _repository.aggregate(tenant, request),
    );
  }

  Stream<DataChangeEvent> _handleWatch(
    WatchChangesRequest request, {
    RpcContext? context,
  }) {
    final tenant = _resolveTenant(context);
    return _repository.watch(tenant, request).handleError((error, stackTrace) {
      if (error is RpcError) {
        throw error;
      }
      throw RpcError.internal('Failed to stream changes', error: error);
    });
  }

  Stream<SyncChangeResponse> _handleSync(
    Stream<SyncChangeRequest> requests, {
    RpcContext? context,
  }) {
    final tenant = _resolveTenant(context);
    return _repository.sync(tenant, requests).handleError((error, stackTrace) {
      if (error is RpcError) {
        throw error;
      }
      throw RpcError.internal('Failed to sync changes', error: error);
    });
  }

  String _resolveTenant(RpcContext? context) {
    final tenant = context?.getHeader('x-tenant-id');
    final authHeader = context?.getHeader('authorization');
    if (tenant == null || tenant.isEmpty) {
      throw RpcError.unauthenticated('Header x-tenant-id is required');
    }
    if (authHeader == null || !authHeader.startsWith('Bearer ')) {
      throw RpcError.permissionDenied('Bearer token is required');
    }
    if (context?.isExpired ?? false) {
      throw RpcError.deadlineExceeded('Deadline exceeded for request ${context?.requestId}');
    }
    return tenant;
  }

  Future<T> _runSafely<T>(RpcContext? context, Future<T> Function() action) async {
    try {
      context?.cancellationToken?.throwIfCancelled();
      return await action();
    } on RpcCancelledException catch (error) {
      throw RpcError.cancelled(error.message);
    } on RpcDeadlineExceededException catch (_) {
      throw RpcError.deadlineExceeded('Deadline exceeded for request ${context?.requestId}');
    } on RpcError {
      rethrow;
    } catch (error) {
      throw RpcError.internal('Unhandled repository error', error: error);
    }
  }

  @override
  Future<void> dispose() async {
    await _repository.dispose();
    super.dispose();
  }
}
