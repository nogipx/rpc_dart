// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_data/rpc_data.dart';

/// IDataClient implementation that works directly with an IDataRepository
/// without RPC plumbing. Useful for in-process setups and tests.
class DataRepositoryClient implements IDataClient {
  DataRepositoryClient({
    required IDataRepository repository,
    bool disposeRepositoryOnClose = false,
    LogScope? logger,
  }) : _repository = repository,
       _disposeRepositoryOnClose = disposeRepositoryOnClose,
       _log = logger ?? LogScope.noop;

  final IDataRepository _repository;
  final bool _disposeRepositoryOnClose;
  final LogScope _log;

  @override
  Future<DataRecord> create({
    required String collection,
    required Map<String, dynamic> payload,
    String? id,
    RpcContext? context,
  }) {
    return _runSafely(
      context,
      () => _repository.create(
        CreateRecordRequest(collection: collection, payload: payload, id: id),
      ),
    );
  }

  @override
  Future<DataRecord?> get({
    required String collection,
    required String id,
    RpcContext? context,
  }) {
    return _runSafely(
      context,
      () => _repository.get(GetRecordRequest(collection: collection, id: id)),
    );
  }

  @override
  Future<ListRecordsResponse> list({
    required String collection,
    RecordFilter? filter,
    SortOrder? sort,
    QueryOptions options = const QueryOptions(),
    RpcContext? context,
  }) {
    return _runSafely(
      context,
      () => _repository.list(
        ListRecordsRequest(
          collection: collection,
          filter: filter,
          sort: sort,
          options: options,
        ),
      ),
    );
  }

  @override
  Future<List<String>> listCollections({RpcContext? context}) {
    return _runSafely(context, () => _repository.listCollections());
  }

  @override
  Future<List<DataRecord>> listAllRecords({
    required String collection,
    RecordFilter? filter,
    SortOrder? sort,
    RpcContext? context,
  }) async {
    final aggregated = <DataRecord>[];
    String? cursor;
    do {
      final page = await list(
        collection: collection,
        filter: filter,
        sort: sort,
        options: QueryOptions(limit: 50, cursor: cursor),
        context: context,
      );
      aggregated.addAll(page.records);
      cursor = page.nextCursor;
    } while (cursor != null);
    return aggregated;
  }

  @override
  Future<DataRecord> update({
    required String collection,
    required String id,
    required int expectedVersion,
    required Map<String, dynamic> payload,
    RpcContext? context,
  }) {
    return _runSafely(
      context,
      () => _repository.update(
        UpdateRecordRequest(
          collection: collection,
          id: id,
          expectedVersion: expectedVersion,
          payload: payload,
        ),
      ),
    );
  }

  @override
  Future<DataRecord> patch({
    required String collection,
    required String id,
    required int expectedVersion,
    required RecordPatch patch,
    RpcContext? context,
  }) {
    return _runSafely(
      context,
      () => _repository.patch(
        PatchRecordRequest(
          collection: collection,
          id: id,
          expectedVersion: expectedVersion,
          patch: patch,
        ),
      ),
    );
  }

  @override
  Future<bool> delete({
    required String collection,
    required String id,
    int? expectedVersion,
    RpcContext? context,
  }) {
    return _runSafely(
      context,
      () => _repository.delete(
        DeleteRecordRequest(
          collection: collection,
          id: id,
          expectedVersion: expectedVersion,
        ),
      ),
    );
  }

  @override
  Future<bool> deleteCollection({
    required String collection,
    RpcContext? context,
  }) {
    return _runSafely(
      context,
      () => _repository.deleteCollection(
        DeleteCollectionRequest(collection: collection),
      ),
    );
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
    return _runSafely(
      context,
      () async {
        final collected = await records.toList();
        if (collected.isEmpty) return const <DataRecord>[];
        return _repository.bulkUpsert(BulkUpsertRequest(records: collected));
      },
    );
  }

  @override
  Future<int> bulkDelete({
    required String collection,
    required List<String> ids,
    RpcContext? context,
  }) {
    return _runSafely(
      context,
      () => _repository.bulkDelete(
        BulkDeleteRequest(collection: collection, ids: ids),
      ),
    );
  }

  @override
  Future<ExportSnapshotResponse> exportSnapshot({
    required String collection,
    RpcContext? context,
  }) {
    return _runSafely(
      context,
      () => _repository.exportSnapshot(
        ExportSnapshotRequest(collection: collection),
      ),
    );
  }

  @override
  Stream<Uint8List> exportDatabase({RpcContext? context}) async* {
    _ensureContext(context);
    try {
      yield* _repository.exportDatabase(const ExportDatabaseRequest());
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
  Future<ImportDatabaseResponse> importDatabase({
    required Stream<Uint8List> payload,
    bool replaceExisting = true,
    int resumeAfterChunk = -1,
    RpcContext? context,
  }) async {
    _ensureContext(context);
    context?.cancellationToken?.throwIfCancelled();
    var lastAck = -1;
    try {
      final response = await _repository.importDatabase(
        payload: payload,
        replaceExisting: replaceExisting,
        resumeAfterChunk: resumeAfterChunk,
        onChunkProcessed: (index) => lastAck = index,
      );
      return response;
    } on RpcCancelledException catch (error) {
      throw RpcDataError.cancelled(error.message);
    } on RpcDeadlineExceededException catch (_) {
      throw RpcDataError.deadlineExceeded(
        'Deadline exceeded for request ${context?.requestId}',
      );
    } catch (error, stackTrace) {
      final resumeIndex = lastAck >= 0
          ? lastAck
          : _extractLastChunkIndex(error.toString());
      if (resumeIndex != null) {
        Error.throwWithStackTrace(
          ImportResumeException(
            'Import failed, resume with resumeAfterChunk=$resumeIndex',
            lastChunkIndex: resumeIndex,
            cause: error,
          ),
          stackTrace,
        );
      }
      if (error is RpcDataError) {
        rethrow;
      }
      _log.error(
        'Unhandled repository error',
        error: error,
        stackTrace: stackTrace,
      );
      Error.throwWithStackTrace(
        RpcDataError.internal('Unhandled repository error', error: error),
        stackTrace,
      );
    }
  }

  @override
  Future<SearchRecordsResponse> search({
    required String collection,
    required String query,
    RecordFilter? filter,
    QueryOptions options = const QueryOptions(),
    RpcContext? context,
  }) {
    return _runSafely(
      context,
      () => _repository.search(
        SearchRecordsRequest(
          collection: collection,
          query: query,
          filter: filter,
          options: options,
        ),
      ),
    );
  }

  @override
  Future<CollectionIndex> createCollectionIndex({
    required String collection,
    required String path,
    String? indexName,
    RpcContext? context,
  }) {
    return _runSafely(
      context,
      () => _repository.createCollectionIndex(
        CreateCollectionIndexRequest(
          collection: collection,
          path: path,
          indexName: indexName,
        ),
      ),
    );
  }

  @override
  Future<bool> deleteCollectionIndex({
    required String collection,
    required String path,
    String? indexName,
    RpcContext? context,
  }) {
    return _runSafely(
      context,
      () => _repository.deleteCollectionIndex(
        DeleteCollectionIndexRequest(
          collection: collection,
          path: path,
          indexName: indexName,
        ),
      ),
    );
  }

  @override
  Stream<DataChangeEvent> watchChanges({
    required String collection,
    String? cursor,
    RpcContext? context,
  }) {
    _ensureContext(context);
    return _repository
        .watch(WatchChangesRequest(collection: collection, cursor: cursor))
        .handleError((error, stackTrace) {
          if (error is RpcDataError) throw error;
          throw RpcDataError.internal('Failed to stream changes', error: error);
        });
  }

  @override
  Future<ListSchemasResponse> listSchemas({RpcContext? context}) {
    return _runSafely(context, () => _repository.listSchemas());
  }

  @override
  Future<GetSchemaResponse> getSchema({
    required String collection,
    RpcContext? context,
  }) {
    return _runSafely(
      context,
      () => _repository.getSchema(GetSchemaRequest(collection: collection)),
    );
  }

  @override
  Future<SetSchemaPolicyResponse> setSchemaPolicy({
    required String collection,
    required bool enabled,
    required bool requireValidation,
    RpcContext? context,
  }) {
    return _runSafely(
      context,
      () => _repository.setSchemaPolicy(
        SetSchemaPolicyRequest(
          collection: collection,
          enabled: enabled,
          requireValidation: requireValidation,
        ),
      ),
    );
  }

  Future<T> _runSafely<T>(
    RpcContext? context,
    Future<T> Function() action,
  ) async {
    try {
      _ensureContext(context);
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
    } catch (error, stackTrace) {
      _log.error(
        'Unhandled repository error',
        error: error,
        stackTrace: stackTrace,
      );
      Error.throwWithStackTrace(
        RpcDataError.internal('Unhandled repository error', error: error),
        stackTrace,
      );
    }
  }

  void _ensureContext(RpcContext? context) {
    if (context?.isExpired ?? false) {
      throw RpcDataError.deadlineExceeded(
        'Deadline exceeded for request ${context?.requestId}',
      );
    }
  }

  @override
  Future<void> close() async {
    if (_disposeRepositoryOnClose) {
      await _repository.dispose();
    }
  }
}

int? _extractLastChunkIndex(String message) {
  final match = RegExp(r'lastChunkIndex=(\\d+)').firstMatch(message);
  if (match == null) return null;
  return int.tryParse(match.group(1)!);
}
