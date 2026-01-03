// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_data/rpc_dart_data.dart';

class DataServiceResponder extends RpcResponderContract
    implements IDataServiceContract {
  DataServiceResponder({
    required IDataRepository repository,
    bool disposeRepositoryOnClose = true,
    Iterable<String> allowedBearerTokens = const [],
    required RpcDataTransferMode transferMode,
    int importAckEveryChunks = 32,
  }) : _repository = repository,
       _disposeRepositoryOnClose = disposeRepositoryOnClose,
       _allowedBearerTokens = {
         for (final token in allowedBearerTokens)
           if (token.trim().isNotEmpty) token.trim(),
       },
       _importAckEveryChunks = importAckEveryChunks,
       assert(importAckEveryChunks > 0, 'importAckEveryChunks must be > 0'),
       super(IDataServiceContract.name, dataTransferMode: transferMode);

  final IDataRepository _repository;
  final Set<String> _allowedBearerTokens;
  final int _importAckEveryChunks;

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

    addUnaryMethod<ListCollectionsRequest, ListCollectionsResponse>(
      methodName: IDataServiceContract.listCollections,
      handler: _handleListCollections,
      requestCodec: listCollectionsRequestCodec,
      responseCodec: listCollectionsResponseCodec,
      description: 'Список существующих коллекций',
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

    addServerStreamMethod<ExportDatabaseRequest, DatabaseChunk>(
      methodName: IDataServiceContract.exportDatabase,
      handler: _handleExportDatabaseStream,
      requestCodec: exportDatabaseRequestCodec,
      responseCodec: databaseChunkCodec,
      description: 'Полный экспорт базы данных (стрим NDJSON чанков)',
    );

    addBidirectionalMethod<DatabaseChunk, ImportProgress>(
      methodName: IDataServiceContract.importDatabase,
      handler: _handleImportDatabaseBidirectional,
      requestCodec: databaseChunkCodec,
      responseCodec: importProgressCodec,
      description:
          'Импорт полной базы данных из NDJSON чанков с ACK прогрессом',
    );

    addUnaryMethod<SearchRecordsRequest, SearchRecordsResponse>(
      methodName: IDataServiceContract.searchRecords,
      handler: _handleSearch,
      requestCodec: searchRequestCodec,
      responseCodec: searchResponseCodec,
      description: 'Полнотекстовый поиск по коллекции',
    );

    addUnaryMethod<CreateCollectionIndexRequest, CreateCollectionIndexResponse>(
      methodName: IDataServiceContract.createCollectionIndex,
      handler: _handleCreateIndex,
      requestCodec: createIndexRequestCodec,
      responseCodec: createIndexResponseCodec,
      description: 'Создание индексированного выражения для JSON-поля',
    );

    addUnaryMethod<DeleteCollectionIndexRequest, DeleteCollectionIndexResponse>(
      methodName: IDataServiceContract.deleteCollectionIndex,
      handler: _handleDeleteIndex,
      requestCodec: deleteIndexRequestCodec,
      responseCodec: deleteIndexResponseCodec,
      description: 'Удаление индексированного выражения коллекции',
    );

    addServerStreamMethod<WatchChangesRequest, DataChangeEvent>(
      methodName: IDataServiceContract.watchChanges,
      handler: _handleWatch,
      requestCodec: watchRequestCodec,
      responseCodec: changeEventCodec,
      description: 'Стрим изменений коллекции с курсором',
    );

    addUnaryMethod<ListSchemasRequest, ListSchemasResponse>(
      methodName: IDataServiceContract.listSchemas,
      handler: _handleListSchemas,
      requestCodec: listSchemasRequestCodec,
      responseCodec: listSchemasResponseCodec,
      description: 'Список активных схем коллекций',
    );

    addUnaryMethod<GetSchemaRequest, GetSchemaResponse>(
      methodName: IDataServiceContract.getSchema,
      handler: _handleGetSchema,
      requestCodec: getSchemaRequestCodec,
      responseCodec: getSchemaResponseCodec,
      description: 'Получение схемы коллекции',
    );

    addUnaryMethod<SetSchemaPolicyRequest, SetSchemaPolicyResponse>(
      methodName: IDataServiceContract.setSchemaPolicy,
      handler: _handleSetSchemaPolicy,
      requestCodec: setSchemaPolicyRequestCodec,
      responseCodec: setSchemaPolicyResponseCodec,
      description: 'Установка политики схемы коллекции',
    );
  }

  Future<CreateRecordResponse> _handleCreate(
    CreateRecordRequest request, {
    RpcContext? context,
  }) async {
    final record = await _runSafely(context, () => _repository.create(request));
    return CreateRecordResponse(record: record);
  }

  Future<GetRecordResponse> _handleGet(
    GetRecordRequest request, {
    RpcContext? context,
  }) async {
    final record = await _runSafely(context, () => _repository.get(request));
    return GetRecordResponse(record: record);
  }

  Future<ListRecordsResponse> _handleList(
    ListRecordsRequest request, {
    RpcContext? context,
  }) async {
    return _runSafely(context, () => _repository.list(request));
  }

  Future<ListCollectionsResponse> _handleListCollections(
    ListCollectionsRequest request, {
    RpcContext? context,
  }) async {
    final collections = await _runSafely(
      context,
      () => _repository.listCollections(),
    );
    return ListCollectionsResponse(collections: collections);
  }

  Future<UpdateRecordResponse> _handleUpdate(
    UpdateRecordRequest request, {
    RpcContext? context,
  }) async {
    final record = await _runSafely(context, () => _repository.update(request));
    return UpdateRecordResponse(record: record);
  }

  Future<PatchRecordResponse> _handlePatch(
    PatchRecordRequest request, {
    RpcContext? context,
  }) async {
    final record = await _runSafely(context, () => _repository.patch(request));
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
    return _runSafely(context, () => _repository.exportSnapshot(request));
  }

  Stream<DatabaseChunk> _handleExportDatabaseStream(
    ExportDatabaseRequest request, {
    RpcContext? context,
  }) async* {
    _ensureAuthorized(context);
    try {
      var chunkIndex = 0;
      await for (final bytes in _repository.exportDatabase(request)) {
        yield DatabaseChunk(bytes: bytes, chunkIndex: chunkIndex++);
      }
    } catch (error, stackTrace) {
      if (error is RpcDataError) {
        Error.throwWithStackTrace(error, stackTrace);
      }
      Error.throwWithStackTrace(
        RpcDataError.internal('Failed to export database', error: error),
        stackTrace,
      );
    }
  }

  Stream<ImportProgress> _handleImportDatabaseBidirectional(
    Stream<DatabaseChunk> chunks, {
    RpcContext? context,
  }) {
    _ensureAuthorized(context);
    return Stream<ImportProgress>.multi((emitter) async {
      final iterator = StreamIterator<DatabaseChunk>(chunks);
      if (!await iterator.moveNext()) {
        try {
          final response = await _runSafely(
            context,
            () => _repository.importDatabase(
              payload: const Stream<Uint8List>.empty(),
              replaceExisting: true,
              resumeAfterChunk: -1,
              onChunkProcessed: (index) => _maybeAck(
                index,
                emitter,
                _importAckEveryChunks,
                allowFirst: false,
              ),
            ),
          );
          emitter.add(
            ImportProgress(
              lastChunkIndex: response.lastChunkIndex,
              result: response,
            ),
          );
          emitter.close();
        } catch (error, stackTrace) {
          emitter.addError(error, stackTrace);
        }
        return;
      }

      var replaceExisting = iterator.current.replaceExisting ?? true;
      var replaceSeen = iterator.current.replaceExisting != null;
      var resumeAfterChunk = iterator.current.resumeAfterChunk ?? -1;
      var resumeSeen = iterator.current.resumeAfterChunk != null;
      var lastAck = -1;

      Stream<Uint8List> replay() async* {
        yield iterator.current.bytes;
        while (await iterator.moveNext()) {
          final chunk = iterator.current;
          if (!replaceSeen && chunk.replaceExisting != null) {
            replaceExisting = chunk.replaceExisting!;
            replaceSeen = true;
          }
          if (!resumeSeen && chunk.resumeAfterChunk != null) {
            resumeAfterChunk = chunk.resumeAfterChunk!;
            resumeSeen = true;
          }
          yield chunk.bytes;
        }
      }

      try {
        final response = await _runSafely(
          context,
          () => _repository.importDatabase(
            payload: replay(),
            replaceExisting: replaceExisting,
            resumeAfterChunk: resumeAfterChunk,
            onChunkProcessed: (index) {
              lastAck = _maybeAck(
                index,
                emitter,
                _importAckEveryChunks,
                lastAck: lastAck,
                allowFirst: false,
              );
            },
          ),
        );
        lastAck = _maybeAck(
          response.lastChunkIndex,
          emitter,
          _importAckEveryChunks,
          lastAck: lastAck,
        );
        emitter.add(
          ImportProgress(
            lastChunkIndex: response.lastChunkIndex,
            result: response,
          ),
        );
        emitter.close();
      } catch (error, stackTrace) {
        emitter.addError(error, stackTrace);
      }
    });
  }

  int _maybeAck(
    int index,
    StreamSink<ImportProgress> emitter,
    int ackEveryChunks, {
    int lastAck = -1,
    bool allowFirst = true,
  }) {
    final isFirst = lastAck == -1;
    final shouldAck =
        (!isFirst || allowFirst) &&
        (isFirst || (index - lastAck) >= ackEveryChunks);
    if (shouldAck) {
      emitter.add(ImportProgress(lastChunkIndex: index));
      return index;
    }
    return lastAck;
  }

  Future<SearchRecordsResponse> _handleSearch(
    SearchRecordsRequest request, {
    RpcContext? context,
  }) async {
    return _runSafely(context, () => _repository.search(request));
  }

  Future<ListSchemasResponse> _handleListSchemas(
    ListSchemasRequest request, {
    RpcContext? context,
  }) async {
    return _runSafely(context, () => _repository.listSchemas());
  }

  Future<GetSchemaResponse> _handleGetSchema(
    GetSchemaRequest request, {
    RpcContext? context,
  }) async {
    return _runSafely(context, () => _repository.getSchema(request));
  }

  Future<SetSchemaPolicyResponse> _handleSetSchemaPolicy(
    SetSchemaPolicyRequest request, {
    RpcContext? context,
  }) async {
    return _runSafely(context, () => _repository.setSchemaPolicy(request));
  }

  Future<CreateCollectionIndexResponse> _handleCreateIndex(
    CreateCollectionIndexRequest request, {
    RpcContext? context,
  }) async {
    final index = await _runSafely(
      context,
      () => _repository.createCollectionIndex(request),
    );
    return CreateCollectionIndexResponse(index: index);
  }

  Future<DeleteCollectionIndexResponse> _handleDeleteIndex(
    DeleteCollectionIndexRequest request, {
    RpcContext? context,
  }) async {
    final deleted = await _runSafely(
      context,
      () => _repository.deleteCollectionIndex(request),
    );
    return DeleteCollectionIndexResponse(deleted: deleted);
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

  void _ensureAuthorized(RpcContext? context) {
    if (context?.isExpired ?? false) {
      throw RpcDataError.deadlineExceeded(
        'Deadline exceeded for request ${context?.requestId}',
      );
    }
    if (_allowedBearerTokens.isEmpty) {
      return;
    }
    final authHeader = context?.getHeader('authorization');
    if (authHeader == null || authHeader.trim().isEmpty) {
      throw RpcDataError.permissionDenied(
        'Authorization header is required for this service',
      );
    }
    if (!authHeader.startsWith('Bearer ')) {
      throw RpcDataError.permissionDenied(
        'Authorization header must use the Bearer scheme',
      );
    }
    final token = authHeader.substring(7).trim();
    if (token.isEmpty) {
      throw RpcDataError.permissionDenied(
        'Authorization header is required for this service',
      );
    }
    if (!_allowedBearerTokens.contains(token)) {
      throw RpcDataError.permissionDenied('Bearer token is invalid');
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
