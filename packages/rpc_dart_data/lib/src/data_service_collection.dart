import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_data/rpc_dart_data.dart';

typedef FromJson<T> = T Function(Map<String, dynamic> json);
typedef ToJson<T> = Map<String, dynamic> Function(T model);

/// Wraps a data operation with logging on error while preserving the original exception.
Future<T> _guard<T>({
  required RpcLogger log,
  required String operation,
  required Future<T> Function() run,
}) async {
  try {
    return await run();
  } on Object catch (error, stackTrace) {
    log.error(
      'Failed operation: $operation',
      error: error,
      stackTrace: stackTrace,
    );
    rethrow;
  }
}

abstract interface class IDataServiceCollection<T> {
  String get collection;

  Future<Versioned<T>?> get(String id, {RpcContext? context});

  Future<Versioned<T>> create(T model, {RpcContext? context});

  Future<List<Versioned<T>>> list({
    RecordFilter? filter,
    QueryOptions? options,
    SortOrder? sort,
    RpcContext? context,
  });

  Future<Versioned<T>> update(
    T model, {
    required int expectedVersion,
    RpcContext? context,
  });

  Future<Versioned<T>> upsert(T model, {RpcContext? context});

  Future<Versioned<T>> patch({
    required String id,
    required int expectedVersion,
    required RecordPatch patch,
    RpcContext? context,
  });

  Future<bool> delete(String id, {RpcContext? context});

  Future<int> bulkDelete(List<String> ids, {RpcContext? context});

  Stream<CollectionChange<T>> watchChanges({
    String? cursor,
    RpcContext? context,
  });
}

/// Typed wrapper around a single IDataService collection.
class DataServiceCollection<T> implements IDataServiceCollection<T> {
  DataServiceCollection({
    required this.collection,
    required this.dataService,
    required this.fromJson,
    required this.toJson,
    required this.idSelector,
    this.idField = 'id',
    RpcLogger? customLog,
  }) : log = customLog ?? RpcLogger('DataCollection:$collection');

  @override
  final String collection;
  final IDataService dataService;
  final RpcLogger log;
  final FromJson<T> fromJson;
  final ToJson<T> toJson;
  final String Function(T model) idSelector;
  final String idField;

  Versioned<T> _fromRecord(DataRecord record) {
    final payload = Map<String, dynamic>.from(record.payload);
    if (!payload.containsKey(idField)) {
      payload[idField] = record.id;
    }
    return Versioned(fromJson(payload), record.version);
  }

  @override
  Future<Versioned<T>?> get(String id, {RpcContext? context}) async {
    return _guard(
      log: log,
      operation: 'get:$collection/$id',
      run: () async {
        final record = await dataService.get(
          collection: collection,
          id: id,
          context: context,
        );
        return record == null ? null : _fromRecord(record);
      },
    );
  }

  @override
  Future<Versioned<T>> create(T model, {RpcContext? context}) async {
    final id = idSelector(model);
    final payload = toJson(model);
    return _guard(
      log: log,
      operation: 'create:$collection/$id',
      run: () async {
        final record = await dataService.create(
          collection: collection,
          payload: payload,
          id: id,
          context: context,
        );
        return _fromRecord(record);
      },
    );
  }

  @override
  Future<List<Versioned<T>>> list({
    RecordFilter? filter,
    QueryOptions? options,
    SortOrder? sort,
    RpcContext? context,
  }) async {
    return _guard(
      log: log,
      operation: 'list:$collection',
      run: () async {
        if (options != null) {
          final response = await dataService.list(
            collection: collection,
            filter: filter,
            sort: sort,
            options: options,
            context: context,
          );
          return response.records.map(_fromRecord).toList(growable: false);
        }

        final all = await dataService.listAllRecords(
          collection: collection,
          filter: filter,
          sort: sort,
          context: context,
        );
        return all.map(_fromRecord).toList(growable: false);
      },
    );
  }

  @override
  Future<Versioned<T>> update(
    T model, {
    required int expectedVersion,
    RpcContext? context,
  }) async {
    final id = idSelector(model);
    final payload = toJson(model);
    return _guard(
      log: log,
      operation: 'update:$collection/$id@$expectedVersion',
      run: () async {
        final record = await dataService.update(
          collection: collection,
          id: id,
          expectedVersion: expectedVersion,
          payload: payload,
          context: context,
        );
        return _fromRecord(record);
      },
    );
  }

  @override
  Future<Versioned<T>> upsert(T model, {RpcContext? context}) async {
    final id = idSelector(model);
    final payload = toJson(model);
    return _guard(
      log: log,
      operation: 'upsert:$collection/$id',
      run: () async {
        final existing = await dataService.get(
          collection: collection,
          id: id,
          context: context,
        );

        if (existing == null) {
          final created = await dataService.create(
            collection: collection,
            id: id,
            payload: payload,
            context: context,
          );
          return _fromRecord(created);
        }

        final updated = await dataService.update(
          collection: collection,
          id: id,
          expectedVersion: existing.version,
          payload: payload,
          context: context,
        );
        return _fromRecord(updated);
      },
    );
  }

  @override
  Future<Versioned<T>> patch({
    required String id,
    required int expectedVersion,
    required RecordPatch patch,
    RpcContext? context,
  }) async {
    return _guard(
      log: log,
      operation: 'patch:$collection/$id@$expectedVersion',
      run: () async {
        final record = await dataService.patch(
          collection: collection,
          id: id,
          expectedVersion: expectedVersion,
          patch: patch,
          context: context,
        );
        return _fromRecord(record);
      },
    );
  }

  @override
  Future<bool> delete(String id, {RpcContext? context}) {
    return _guard(
      log: log,
      operation: 'delete:$collection/$id',
      run: () =>
          dataService.delete(collection: collection, id: id, context: context),
    );
  }

  @override
  Future<int> bulkDelete(List<String> ids, {RpcContext? context}) {
    return _guard(
      log: log,
      operation: 'bulkDelete:$collection/${ids.length}',
      run: () => dataService.bulkDelete(
        collection: collection,
        ids: ids,
        context: context,
      ),
    );
  }

  @override
  Stream<CollectionChange<T>> watchChanges({
    String? cursor,
    RpcContext? context,
  }) {
    return dataService
        .watchChanges(collection: collection, cursor: cursor, context: context)
        .map(
          (event) => CollectionChange<T>(
            type: event.type,
            collection: event.collection,
            id: event.id,
            version: event.version,
            cursor: event.cursor,
            occurredAt: event.occurredAt,
            record: event.record == null ? null : _fromRecord(event.record!),
          ),
        );
  }
}

class Versioned<T> {
  const Versioned(this.data, this.version);

  final T data;
  final int version;
}

class CollectionChange<T> {
  const CollectionChange({
    required this.type,
    required this.collection,
    required this.id,
    required this.version,
    required this.cursor,
    required this.occurredAt,
    this.record,
  });

  final DataChangeType type;
  final String collection;
  final String id;
  final int version;
  final String cursor;
  final DateTime occurredAt;
  final Versioned<T>? record;
}
