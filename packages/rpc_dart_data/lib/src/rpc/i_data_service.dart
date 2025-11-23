import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_data/rpc_dart_data.dart';

/// High-level facade that encapsulates RPC plumbing for the data service.
///
/// Goals:
/// * Hide RpcCallerEndpoint / RpcResponderEndpoint details from application code;
/// * Provide a single interface for deploying the service (server side) and calling it (client side);
/// * Simplify in-memory setups (tests, demos, local dev);
/// * Centralize advanced settings (dataTransferMode, repository, etc.) in one place.
///
/// If needed you can still use the low-level classes (DataServiceCaller / DataServiceResponder)
/// directly — they keep working as before.

/// Unified interface for CRUD/Query operations.
/// Returns already “unpacked” data instead of *Response objects where it makes sense.
abstract interface class IDataService {
  /// Creates a record in the collection and returns the stored document with id/version set.
  ///
  /// If `id` is not provided, the provider generates it (typically ULID/UUID). Authorization
  /// and validation are handled by the implementation; errors arrive as `RpcDataError`.
  Future<DataRecord> create({
    required String collection,
    required Map<String, dynamic> payload,
    String? id,
    RpcContext? context,
  });

  /// Returns a record by id or `null` when the record does not exist.
  ///
  /// Does not throw `NOT_FOUND` — absence is a valid scenario (useful for caches and
  /// idempotent logic).
  Future<DataRecord?> get({
    required String collection,
    required String id,
    RpcContext? context,
  });

  /// Returns a page of records with filtering, sorting, and pagination applied.
  ///
  /// `options.limit`/`options.cursor` control pagination. Provide `sort` to get a
  /// deterministic order (and page correctly). For large exports prefer `listAllRecords`
  /// or export operations.
  Future<ListRecordsResponse> list({
    required String collection,
    RecordFilter? filter,
    SortOrder? sort,
    QueryOptions options,
    RpcContext? context,
  });

  /// Returns the list of available collections (data namespaces).
  Future<List<String>> listCollections({RpcContext? context});

  /// Dumps the entire collection by iterating `list` pages.
  ///
  /// Handy for tests, migrations, and debugging. For very large volumes prefer
  /// streaming/export operations.
  Future<List<DataRecord>> listAllRecords({
    required String collection,
    RecordFilter? filter,
    SortOrder? sort,
    RpcContext? context,
  });

  /// Fully replaces a record, checking the expected version (optimistic locking).
  ///
  /// If `expectedVersion` mismatches, an `RpcDataError.conflict` is returned so the
  /// caller can retry after re-reading.
  Future<DataRecord> update({
    required String collection,
    required String id,
    required int expectedVersion,
    required Map<String, dynamic> payload,
    RpcContext? context,
  });

  /// Applies a patch to a record, checking the expected version (optimistic locking).
  ///
  /// The patch is described by `RecordPatch` (add/replace/remove). On version conflict
  /// returns `RpcDataError.conflict`.
  Future<DataRecord> patch({
    required String collection,
    required String id,
    required int expectedVersion,
    required RecordPatch patch,
    RpcContext? context,
  });

  /// Deletes a record and returns a success flag.
  ///
  /// When `expectedVersion` is set the delete is version-checked; otherwise it proceeds
  /// without version control.
  Future<bool> delete({
    required String collection,
    required String id,
    int? expectedVersion,
    RpcContext? context,
  });

  /// Drops a collection and all its data.
  ///
  /// Can be unavailable in some environments (read-only/managed).
  Future<bool> deleteCollection({
    required String collection,
    RpcContext? context,
  });

  /// Bulk upsert of a list of records.
  ///
  /// Accepts prepared `DataRecord` objects (optionally with id/version). Partial success
  /// depends on the implementation; results/errors are returned in the response.
  Future<List<DataRecord>> bulkUpsert({
    required Iterable<DataRecord> records,
    RpcContext? context,
  });

  /// Streaming variant of bulk upsert.
  ///
  /// Suitable for large volumes: the provider may consume the stream with backpressure.
  /// Returns the list of successfully processed records/results.
  Future<List<DataRecord>> bulkUpsertStream({
    required Stream<DataRecord> records,
    RpcContext? context,
  });

  /// Bulk delete by record ids, returning the number deleted.
  ///
  /// Split into smaller batches if you need finer error handling.
  Future<int> bulkDelete({
    required String collection,
    required List<String> ids,
    RpcContext? context,
  });

  /// Exports a snapshot of a collection.
  ///
  /// Useful for backups/migrations of specific collections. Format depends on the codec
  /// (often a JSON-compatible payload).
  Future<ExportSnapshotResponse> exportSnapshot({
    required String collection,
    RpcContext? context,
  });

  /// Exports the entire database.
  ///
  /// Can be heavy and may be disabled by policy.
  Future<ExportDatabaseResponse> exportDatabase({RpcContext? context});

  /// Imports the database from a serialized dump.
  ///
  /// With `replaceExisting=true` existing data may be overwritten/cleared — use cautiously
  /// in production.
  Future<ImportDatabaseResponse> importDatabase({
    required String payload,
    bool replaceExisting = true,
    RpcContext? context,
  });

  /// Performs full-text/indexed search over a collection with filters and query options.
  ///
  /// Full-text support depends on the backend. Prefer setting a limit and sorting by
  /// relevance or a field.
  Future<SearchRecordsResponse> search({
    required String collection,
    required String query,
    RecordFilter? filter,
    QueryOptions options,
    RpcContext? context,
  });

  /// Calculates aggregates over a collection with an optional filter.
  ///
  /// `metrics` keys represent aggregate expressions/names (e.g., `count`, `sum:price`);
  /// exact syntax is defined by the implementation.
  Future<AggregateMetricsResponse> aggregate({
    required String collection,
    RecordFilter? filter,
    Map<String, String> metrics,
    RpcContext? context,
  });

  /// Creates an index on the specified field path.
  ///
  /// `path` follows the backend’s notation (JSON pointer/dot path). `indexName` lets you
  /// set an explicit index name.
  Future<CollectionIndex> createCollectionIndex({
    required String collection,
    required String path,
    String? indexName,
    RpcContext? context,
  });

  /// Deletes a defined index.
  ///
  /// If `indexName` is not provided, the index is resolved by `path`.
  Future<bool> deleteCollectionIndex({
    required String collection,
    required String path,
    String? indexName,
    RpcContext? context,
  });

  /// Subscribes to a change stream for the selected collection.
  ///
  /// `cursor` lets you resume from the last known position (e.g., after reconnecting).
  /// Events are ordered by commit.
  Stream<DataChangeEvent> watchChanges({
    required String collection,
    String? cursor,
    RpcContext? context,
  });

  /// Bidirectional synchronization of offline commands.
  ///
  /// The client streams commands; the service streams back acknowledgements/results.
  /// Used to reconcile offline work and handle conflicts.
  Stream<SyncChangeResponse> syncChanges(
    Stream<SyncChangeRequest> requests, {
    RpcContext? context,
  });

  /// Sends a single command and waits for its acknowledgement.
  ///
  /// Convenience wrapper over `syncChanges` for one-off calls without stream management.
  Future<SyncChangeResponse> pushAndAwaitAck({
    required SyncChangeRequest request,
    RpcContext? context,
  });

  /// Creates an offline command queue bound to the client.
  ///
  /// Lets you accumulate actions while offline and sync them via `syncChanges`.
  /// `sessionId` ties the queue to a user/device; `clock` can be overridden in tests.
  OfflineCommandQueue createOfflineQueue({
    String? sessionId,
    DateTime Function()? clock,
    void Function(Object error, StackTrace stackTrace)? onError,
  });

  /// Closes the client RPC connection and releases associated resources.
  ///
  /// Call when shutting down app/test to close sockets and cancel active streams.
  Future<void> close();
}
