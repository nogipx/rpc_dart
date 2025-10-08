import 'dart:async';

import 'package:rpc_dart_transports/rpc_dart_transports.dart';

import 'data_contract.dart';
import 'data_repository.dart';
import 'models.dart';

class DataServiceResponder extends RpcResponderContract
    implements IDataServiceContract {
  DataServiceResponder({
    required DataRepository repository,
    bool disposeRepositoryOnClose = true,
  })  : _repository = repository,
        _disposeRepositoryOnClose = disposeRepositoryOnClose,
        super(
          IDataServiceContract.name,
          dataTransferMode: RpcDataTransferMode.codec,
        );

  final DataRepository _repository;
  /// Управляет тем, должен ли [dispose] закрывать репозиторий.
  ///
  /// Это полезно, когда один экземпляр репозитория шарится между
  /// несколькими эндпоинтами, например в случае HTTP/2 сервера.
  final bool _disposeRepositoryOnClose;

  @override
  void setup() {
    addUnaryMethod<CreateRecordRequest, CreateRecordResponse>(
      methodName: IDataServiceContract.createRecord,
      handler: _handleCreate,
      requestCodec: createRequestCodec,
      responseCodec: createResponseCodec,
      description: 'Создание новой записи с проверкой прав и дедлайна',
    );

    addUnaryMethod<GetRecordRequest, GetRecordResponse>(
      methodName: IDataServiceContract.getRecord,
      handler: _handleGet,
      requestCodec: getRequestCodec,
      responseCodec: getResponseCodec,
      description: 'Получение записи по идентификатору',
    );

    addUnaryMethod<ListRecordsRequest, ListRecordsResponse>(
      methodName: IDataServiceContract.listRecords,
      handler: _handleList,
      requestCodec: listRequestCodec,
      responseCodec: listResponseCodec,
      description: 'Постраничный список с фильтрацией и сортировкой',
    );

    addUnaryMethod<UpdateRecordRequest, UpdateRecordResponse>(
      methodName: IDataServiceContract.updateRecord,
      handler: _handleUpdate,
      requestCodec: updateRequestCodec,
      responseCodec: updateResponseCodec,
      description: 'Полное обновление записи c оптимистической конкуренцией',
    );

    addUnaryMethod<PatchRecordRequest, PatchRecordResponse>(
      methodName: IDataServiceContract.patchRecord,
      handler: _handlePatch,
      requestCodec: patchRequestCodec,
      responseCodec: patchResponseCodec,
      description: 'Частичное обновление через RecordPatch',
    );

    addUnaryMethod<DeleteRecordRequest, DeleteRecordResponse>(
      methodName: IDataServiceContract.deleteRecord,
      handler: _handleDelete,
      requestCodec: deleteRequestCodec,
      responseCodec: deleteResponseCodec,
      description: 'Удаление с проверкой версии',
    );

    addUnaryMethod<DeleteCollectionRequest, DeleteCollectionResponse>(
      methodName: IDataServiceContract.deleteCollection,
      handler: _handleDeleteCollection,
      requestCodec: deleteCollectionRequestCodec,
      responseCodec: deleteCollectionResponseCodec,
      description: 'Удаление коллекции и всех записей',
    );

    addClientStreamMethod<DataRecord, BulkUpsertResponse>(
      methodName: IDataServiceContract.bulkUpsert,
      handler: _handleBulkUpsertStream,
      requestCodec: recordCodec,
      responseCodec: bulkUpsertResponseCodec,
      description: 'Пакетный upsert через клиентский стрим',
    );

    addUnaryMethod<BulkDeleteRequest, BulkDeleteResponse>(
      methodName: IDataServiceContract.bulkDelete,
      handler: _handleBulkDelete,
      requestCodec: bulkDeleteRequestCodec,
      responseCodec: bulkDeleteResponseCodec,
      description: 'Массовое удаление записей',
    );

    addUnaryMethod<ExportSnapshotRequest, ExportSnapshotResponse>(
      methodName: IDataServiceContract.exportSnapshot,
      handler: _handleExport,
      requestCodec: exportRequestCodec,
      responseCodec: exportResponseCodec,
      description: 'Экспорт моментального снимка коллекции',
    );

    addUnaryMethod<ExportDatabaseRequest, ExportDatabaseResponse>(
      methodName: IDataServiceContract.exportDatabase,
      handler: _handleExportDatabase,
      requestCodec: exportDatabaseRequestCodec,
      responseCodec: exportDatabaseResponseCodec,
      description: 'Полный экспорт базы данных (с шифрованием по паролю)',
    );

    addUnaryMethod<ImportDatabaseRequest, ImportDatabaseResponse>(
      methodName: IDataServiceContract.importDatabase,
      handler: _handleImportDatabase,
      requestCodec: importDatabaseRequestCodec,
      responseCodec: importDatabaseResponseCodec,
      description: 'Импорт полной базы данных из снапшота',
    );

    addUnaryMethod<SearchRecordsRequest, SearchRecordsResponse>(
      methodName: IDataServiceContract.searchRecords,
      handler: _handleSearch,
      requestCodec: searchRequestCodec,
      responseCodec: searchResponseCodec,
      description: 'Полнотекстовый поиск по коллекции',
    );

    addUnaryMethod<AggregateMetricsRequest, AggregateMetricsResponse>(
      methodName: IDataServiceContract.aggregateMetrics,
      handler: _handleAggregate,
      requestCodec: aggregateRequestCodec,
      responseCodec: aggregateResponseCodec,
      description: 'Агрегирование по полям',
    );

    addServerStreamMethod<WatchChangesRequest, DataChangeEvent>(
      methodName: IDataServiceContract.watchChanges,
      handler: _handleWatch,
      requestCodec: watchRequestCodec,
      responseCodec: changeEventCodec,
      description: 'Стрим изменений коллекции с курсором',
    );

    addBidirectionalMethod<SyncChangeRequest, SyncChangeResponse>(
      methodName: IDataServiceContract.syncChanges,
      handler: _handleSync,
      requestCodec: syncRequestCodec,
      responseCodec: syncResponseCodec,
      description:
          'Двунаправленная синхронизация офлайн клиента (command queue)',
    );
  }

  Future<CreateRecordResponse> _handleCreate(
    CreateRecordRequest request, {
    RpcContext? context,
  }) async {
    final record = await _runSafely(
      context,
      () => _repository.create(request),
    );
    return CreateRecordResponse(record: record);
  }

  Future<GetRecordResponse> _handleGet(
    GetRecordRequest request, {
    RpcContext? context,
  }) async {
    final record = await _runSafely(
      context,
      () => _repository.get(request),
    );
    return GetRecordResponse(record: record);
  }

  Future<ListRecordsResponse> _handleList(
    ListRecordsRequest request, {
    RpcContext? context,
  }) async {
    return _runSafely(context, () => _repository.list(request));
  }

  Future<UpdateRecordResponse> _handleUpdate(
    UpdateRecordRequest request, {
    RpcContext? context,
  }) async {
    final record = await _runSafely(
      context,
      () => _repository.update(request),
    );
    return UpdateRecordResponse(record: record);
  }

  Future<PatchRecordResponse> _handlePatch(
    PatchRecordRequest request, {
    RpcContext? context,
  }) async {
    final record = await _runSafely(
      context,
      () => _repository.patch(request),
    );
    return PatchRecordResponse(record: record);
  }

  Future<DeleteRecordResponse> _handleDelete(
    DeleteRecordRequest request, {
    RpcContext? context,
  }) async {
    final deleted = await _runSafely(
      context,
      () => _repository.delete(request),
    );
    return DeleteRecordResponse(deleted: deleted);
  }

  Future<DeleteCollectionResponse> _handleDeleteCollection(
    DeleteCollectionRequest request, {
    RpcContext? context,
  }) async {
    final deleted = await _runSafely(
      context,
      () => _repository.deleteCollection(request),
    );
    return DeleteCollectionResponse(deleted: deleted);
  }

  Future<BulkUpsertResponse> _handleBulkUpsertStream(
    Stream<DataRecord> records, {
    RpcContext? context,
  }) async {
    final collected = await records.toList();
    if (collected.isEmpty) {
      return const BulkUpsertResponse(records: []);
    }
    final saved = await _runSafely(
      context,
      () => _repository.bulkUpsert(BulkUpsertRequest(records: collected)),
    );
    return BulkUpsertResponse(records: saved);
  }

  Future<BulkDeleteResponse> _handleBulkDelete(
    BulkDeleteRequest request, {
    RpcContext? context,
  }) async {
    final deleted = await _runSafely(
      context,
      () => _repository.bulkDelete(request),
    );
    return BulkDeleteResponse(deletedCount: deleted);
  }

  Future<ExportSnapshotResponse> _handleExport(
    ExportSnapshotRequest request, {
    RpcContext? context,
  }) async {
    return _runSafely(
      context,
      () => _repository.exportSnapshot(request),
    );
  }

  Future<ExportDatabaseResponse> _handleExportDatabase(
    ExportDatabaseRequest request, {
    RpcContext? context,
  }) async {
    return _runSafely(
      context,
      () => _repository.exportDatabase(request),
    );
  }

  Future<ImportDatabaseResponse> _handleImportDatabase(
    ImportDatabaseRequest request, {
    RpcContext? context,
  }) async {
    return _runSafely(
      context,
      () => _repository.importDatabase(request),
    );
  }

  Future<SearchRecordsResponse> _handleSearch(
    SearchRecordsRequest request, {
    RpcContext? context,
  }) async {
    return _runSafely(context, () => _repository.search(request));
  }

  Future<AggregateMetricsResponse> _handleAggregate(
    AggregateMetricsRequest request, {
    RpcContext? context,
  }) async {
    return _runSafely(context, () => _repository.aggregate(request));
  }

  Stream<DataChangeEvent> _handleWatch(
    WatchChangesRequest request, {
    RpcContext? context,
  }) {
    _ensureAuthorized(context);
    return _repository.watch(request).handleError((error, stackTrace) {
      if (error is RpcDataError) {
        throw error;
      }
      throw RpcDataError.internal('Failed to stream changes', error: error);
    });
  }

  Stream<SyncChangeResponse> _handleSync(
    Stream<SyncChangeRequest> requests, {
    RpcContext? context,
  }) {
    _ensureAuthorized(context);
    return _repository.sync(requests).handleError((error, stackTrace) {
      if (error is RpcDataError) {
        throw error;
      }
      throw RpcDataError.internal('Failed to sync changes', error: error);
    });
  }

  void _ensureAuthorized(RpcContext? context) {
    final authHeader = context?.getHeader('authorization');
    if (authHeader == null || !authHeader.startsWith('Bearer ')) {
      throw RpcDataError.permissionDenied('Bearer token is required');
    }
    if (context?.isExpired ?? false) {
      throw RpcDataError.deadlineExceeded(
        'Deadline exceeded for request ${context?.requestId}',
      );
    }
  }

  Future<T> _runSafely<T>(
    RpcContext? context,
    Future<T> Function() action,
  ) async {
    try {
      _ensureAuthorized(context);
      context?.cancellationToken?.throwIfCancelled();
      return await action();
    } on RpcCancelledException catch (error) {
      throw RpcDataError.cancelled(error.message);
    } on RpcDeadlineExceededException catch (_) {
      throw RpcDataError.deadlineExceeded(
        'Deadline exceeded for request ${context?.requestId}',
      );
    } on RpcDataError {
      rethrow;
    } catch (error) {
      throw RpcDataError.internal('Unhandled repository error', error: error);
    }
  }

  @override
  Future<void> dispose() async {
    if (_disposeRepositoryOnClose) {
      await _repository.dispose();
    }
    super.dispose();
  }
}
