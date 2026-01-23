// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_data/rpc_data.dart';

import 'data_contract.dart';

class DataServiceResponder extends DataServiceContractResponder {
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
       super(dataTransferMode: transferMode);

  final IDataRepository _repository;
  final Set<String> _allowedBearerTokens;
  final int _importAckEveryChunks;

  /// Управляет тем, должен ли [dispose] закрывать репозиторий.
  ///
  /// Это полезно, когда один экземпляр репозитория шарится между
  /// несколькими эндпоинтами, например в случае HTTP/2 сервера.
  final bool _disposeRepositoryOnClose;

  @override
  Future<CreateRecordResponse> createRecord(
    CreateRecordRequest request, {
    RpcContext? context,
  }) async {
    final record = await _runSafely(context, () => _repository.create(request));
    return CreateRecordResponse(record: record);
  }

  @override
  Future<GetRecordResponse> getRecord(
    GetRecordRequest request, {
    RpcContext? context,
  }) async {
    final record = await _runSafely(context, () => _repository.get(request));
    return GetRecordResponse(record: record);
  }

  @override
  Future<ListRecordsResponse> listRecords(
    ListRecordsRequest request, {
    RpcContext? context,
  }) async {
    return _runSafely(context, () => _repository.list(request));
  }

  @override
  Future<ListCollectionsResponse> listCollections(
    ListCollectionsRequest request, {
    RpcContext? context,
  }) async {
    final collections = await _runSafely(
      context,
      () => _repository.listCollections(),
    );
    return ListCollectionsResponse(collections: collections);
  }

  @override
  Future<UpdateRecordResponse> updateRecord(
    UpdateRecordRequest request, {
    RpcContext? context,
  }) async {
    final record = await _runSafely(context, () => _repository.update(request));
    return UpdateRecordResponse(record: record);
  }

  @override
  Future<PatchRecordResponse> patchRecord(
    PatchRecordRequest request, {
    RpcContext? context,
  }) async {
    final record = await _runSafely(context, () => _repository.patch(request));
    return PatchRecordResponse(record: record);
  }

  @override
  Future<DeleteRecordResponse> deleteRecord(
    DeleteRecordRequest request, {
    RpcContext? context,
  }) async {
    final deleted = await _runSafely(
      context,
      () => _repository.delete(request),
    );
    return DeleteRecordResponse(deleted: deleted);
  }

  @override
  Future<DeleteCollectionResponse> deleteCollection(
    DeleteCollectionRequest request, {
    RpcContext? context,
  }) async {
    final deleted = await _runSafely(
      context,
      () => _repository.deleteCollection(request),
    );
    return DeleteCollectionResponse(deleted: deleted);
  }

  @override
  Future<BulkUpsertResponse> bulkUpsert(
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

  @override
  Future<BulkDeleteResponse> bulkDelete(
    BulkDeleteRequest request, {
    RpcContext? context,
  }) async {
    final deleted = await _runSafely(
      context,
      () => _repository.bulkDelete(request),
    );
    return BulkDeleteResponse(deletedCount: deleted);
  }

  @override
  Future<ExportSnapshotResponse> exportSnapshot(
    ExportSnapshotRequest request, {
    RpcContext? context,
  }) async {
    return _runSafely(context, () => _repository.exportSnapshot(request));
  }

  @override
  Stream<DatabaseChunk> exportDatabase(
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

  @override
  Stream<ImportProgress> importDatabase(
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

  @override
  Future<SearchRecordsResponse> searchRecords(
    SearchRecordsRequest request, {
    RpcContext? context,
  }) async {
    return _runSafely(context, () => _repository.search(request));
  }

  @override
  Future<ListSchemasResponse> listSchemas(
    ListSchemasRequest request, {
    RpcContext? context,
  }) async {
    return _runSafely(context, () => _repository.listSchemas());
  }

  @override
  Future<GetSchemaResponse> getSchema(
    GetSchemaRequest request, {
    RpcContext? context,
  }) async {
    return _runSafely(context, () => _repository.getSchema(request));
  }

  @override
  Future<SetSchemaPolicyResponse> setSchemaPolicy(
    SetSchemaPolicyRequest request, {
    RpcContext? context,
  }) async {
    return _runSafely(context, () => _repository.setSchemaPolicy(request));
  }

  @override
  Future<CreateCollectionIndexResponse> createCollectionIndex(
    CreateCollectionIndexRequest request, {
    RpcContext? context,
  }) async {
    final index = await _runSafely(
      context,
      () => _repository.createCollectionIndex(request),
    );
    return CreateCollectionIndexResponse(index: index);
  }

  @override
  Future<DeleteCollectionIndexResponse> deleteCollectionIndex(
    DeleteCollectionIndexRequest request, {
    RpcContext? context,
  }) async {
    final deleted = await _runSafely(
      context,
      () => _repository.deleteCollectionIndex(request),
    );
    return DeleteCollectionIndexResponse(deleted: deleted);
  }

  @override
  Stream<DataChangeEvent> watchChanges(
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
