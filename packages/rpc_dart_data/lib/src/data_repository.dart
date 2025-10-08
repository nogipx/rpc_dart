import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'data_contract.dart';
import 'models.dart';

/// Абстракция репозитория данных.
abstract interface class DataRepository {
  Future<DataRecord> create(CreateRecordRequest request);

  Future<DataRecord?> get(GetRecordRequest request);

  Future<ListRecordsResponse> list(ListRecordsRequest request);

  Future<DataRecord> update(UpdateRecordRequest request);

  Future<DataRecord> patch(PatchRecordRequest request);

  Future<bool> delete(DeleteRecordRequest request);

  Future<bool> deleteCollection(DeleteCollectionRequest request);

  Future<List<DataRecord>> bulkUpsert(BulkUpsertRequest request);

  Future<int> bulkDelete(BulkDeleteRequest request);

  Future<ExportSnapshotResponse> exportSnapshot(
    ExportSnapshotRequest request,
  );

  Future<ExportDatabaseResponse> exportDatabase(
    ExportDatabaseRequest request,
  );

  Future<ImportDatabaseResponse> importDatabase(
    ImportDatabaseRequest request,
  );

  Future<SearchRecordsResponse> search(SearchRecordsRequest request);

  Future<AggregateMetricsResponse> aggregate(
    AggregateMetricsRequest request,
  );

  Stream<DataChangeEvent> watch(WatchChangesRequest request);

  Stream<SyncChangeResponse> sync(Stream<SyncChangeRequest> requests);

  Future<void> dispose();
}

/// Адаптер хранилища, который можно реализовать поверх любого backend-а
/// (in-memory, SQLite, Postgres и т.д.).
abstract interface class DataStorageAdapter {
  Future<DataRecord?> readRecord(
    String collection,
    String id,
  );

  Future<List<DataRecord>> readCollection(String collection);

  Future<List<String>> listCollections();

  Future<void> writeRecord(DataRecord record);

  Future<void> writeRecords(Iterable<DataRecord> records);

  Future<bool> deleteRecord(
    String collection,
    String id,
  );

  Future<int> deleteRecords(
    String collection,
    Iterable<String> ids,
  );

  Future<bool> deleteCollection(String collection);

  Future<void> dispose();
}

/// Базовая реализация `DataRepository`, инкапсулирующая общую бизнес-логику
/// и работу с журналом событий. Хранилище делегируется `DataStorageAdapter`,
/// поэтому поверх класса легко собрать адаптеры под SQLite/Postgres/Firestore.
abstract class BaseDataRepository implements DataRepository {
  BaseDataRepository(
    this.storage, {
    DateTime Function()? clock,
    String Function(String collection)? idGenerator,
  })  : _clock = clock ?? (() => DateTime.now().toUtc()),
        _idGenerator = idGenerator,
        _changeController = StreamController<DataChangeEvent>.broadcast();

  static const String _databaseFormatVersion = '1.0.0';

  final DataStorageAdapter storage;
  final DateTime Function() _clock;
  final String Function(String collection)? _idGenerator;
  final StreamController<DataChangeEvent> _changeController;
  final Map<String, List<DataChangeEvent>> _eventJournal = {};
  final Random _random = Random();
  int _cursorSequence = 0;

  List<DataChangeEvent> _history(String collection) {
    return _eventJournal.putIfAbsent(collection, () => <DataChangeEvent>[]);
  }

  String _generateId(String collection) {
    if (_idGenerator != null) {
      return _idGenerator!(collection);
    }
    final suffix = _random.nextInt(1 << 32).toRadixString(16);
    final timestamp = _clock().microsecondsSinceEpoch;
    return '$collection-$timestamp-$suffix';
  }

  DataChangeEvent _recordEvent(
    DataChangeType type,
    DataRecord record,
  ) {
    final cursor = (++_cursorSequence).toString();
    final occurredAt = _clock();
    final event = DataChangeEvent(
      type: type,
      collection: record.collection,
      id: record.id,
      record: record,
      version: record.version,
      cursor: cursor,
      occurredAt: occurredAt,
    );
    final history = _history(record.collection);
    history.add(event);
    _changeController.add(event);
    return event;
  }

  DataChangeEvent _recordDeletion(
    String collection,
    String id,
    int nextVersion,
  ) {
    final cursor = (++_cursorSequence).toString();
    final occurredAt = _clock();
    final event = DataChangeEvent(
      type: DataChangeType.deleted,
      collection: collection,
      id: id,
      record: null,
      version: nextVersion,
      cursor: cursor,
      occurredAt: occurredAt,
    );
    final history = _history(collection);
    history.add(event);
    _changeController.add(event);
    return event;
  }

  dynamic _getFieldValue(DataRecord record, String field) {
    switch (field) {
      case 'id':
        return record.id;
      case 'collection':
        return record.collection;
      case 'version':
        return record.version;
      case 'createdAt':
        return record.createdAt;
      case 'updatedAt':
        return record.updatedAt;
      default:
        return record.payload[field];
    }
  }

  bool _matchesFilter(DataRecord record, RecordFilter? filter) {
    if (filter == null) {
      return true;
    }

    for (final entry in filter.equals.entries) {
      final value = _getFieldValue(record, entry.key);
      if (value != entry.value) {
        return false;
      }
    }

    for (final entry in filter.range.entries) {
      final value = _getFieldValue(record, entry.key);
      if (value is! num) {
        return false;
      }
      final constraint = entry.value;
      if (constraint.min != null) {
        if (constraint.includeMin) {
          if (value < constraint.min!) {
            return false;
          }
        } else if (value <= constraint.min!) {
          return false;
        }
      }
      if (constraint.max != null) {
        if (constraint.includeMax) {
          if (value > constraint.max!) {
            return false;
          }
        } else if (value >= constraint.max!) {
          return false;
        }
      }
    }

    if (filter.containsTerms.isNotEmpty) {
      final haystack = record.payload.values
          .map((v) => v.toString().toLowerCase())
          .join(' ');
      for (final term in filter.containsTerms) {
        if (!haystack.contains(term.toLowerCase())) {
          return false;
        }
      }
    }

    return true;
  }

  Map<String, dynamic> _serializeSnapshot(
    Map<String, List<DataRecord>> collections,
    DateTime generatedAt,
  ) {
    return {
      'formatVersion': _databaseFormatVersion,
      'generatedAt': generatedAt.toIso8601String(),
      'collections': collections.map((key, value) {
        return MapEntry(
          key,
          value.map((record) => record.toJson()).toList(growable: false),
        );
      }),
    };
  }

  Map<String, List<DataRecord>> _parseSnapshotCollections(
    Map<String, dynamic> snapshot,
  ) {
    final rawCollections = snapshot['collections'];
    if (rawCollections is! Map) {
      throw RpcDataError.invalidArgument('Snapshot is missing collections map');
    }
    final collectionsMap = Map<String, dynamic>.from(rawCollections as Map);
    final parsed = <String, List<DataRecord>>{};
    collectionsMap.forEach((key, value) {
      if (value is! List) {
        throw RpcDataError.invalidArgument(
          'Snapshot collection "$key" must be a list',
        );
      }
      final records = value
          .map((entry) => DataRecord.fromJson(
                Map<String, dynamic>.from(entry as Map),
              ))
          .toList(growable: false);
      parsed[key] = records;
    });
    return parsed;
  }

  Map<String, dynamic> _decodeSnapshotPayload(
    ImportDatabaseRequest request,
  ) {
    final decoded = jsonDecode(request.payload);
    if (decoded is! Map) {
      throw RpcDataError.invalidArgument('Invalid snapshot payload');
    }
    return Map<String, dynamic>.from(decoded as Map);
  }

  int _compare(DataRecord a, DataRecord b, SortOrder? sort) {
    if (sort == null) {
      return a.id.compareTo(b.id);
    }

    final valueA = _getFieldValue(a, sort.field);
    final valueB = _getFieldValue(b, sort.field);

    int result;
    if (valueA is Comparable && valueB is Comparable) {
      // Сравниваем напрямую; valueA уже Comparable.
      result = valueA.compareTo(valueB);
    } else {
      result = valueA.toString().compareTo(valueB.toString());
    }

    return sort.descending ? -result : result;
  }

  List<DataRecord> _filterAndSort(
    List<DataRecord> records,
    RecordFilter? filter,
    SortOrder? sort,
  ) {
    final filtered =
        records.where((record) => _matchesFilter(record, filter)).toList();
    filtered.sort((a, b) => _compare(a, b, sort));
    return filtered;
  }

  int _resolveStartIndex(List<DataRecord> records, String? cursor) {
    if (cursor == null) {
      return 0;
    }
    final index = records.indexWhere((record) => record.id == cursor);
    if (index == -1) {
      throw RpcDataError.invalidArgument(
          'Cursor $cursor is not valid for selection');
    }
    return index + 1;
  }

  @override
  Future<DataRecord> create(CreateRecordRequest request) async {
    final existing = request.id == null
        ? null
        : await storage.readRecord(request.collection, request.id!);
    if (existing != null) {
      throw RpcDataError.conflict(
        'Record with id "${request.id}" already exists in ${request.collection}',
      );
    }

    final now = _clock();
    final id = request.id ?? _generateId(request.collection);
    final record = DataRecord(
      id: id,
      collection: request.collection,
      payload: request.payload,
      version: 1,
      createdAt: now,
      updatedAt: now,
    );
    await storage.writeRecord(record);
    _recordEvent(DataChangeType.created, record);
    return record;
  }

  @override
  Future<DataRecord?> get(GetRecordRequest request) {
    return storage.readRecord(request.collection, request.id);
  }

  @override
  Future<ListRecordsResponse> list(ListRecordsRequest request) async {
    final collection = await storage.readCollection(request.collection);
    final filtered = _filterAndSort(collection, request.filter, request.sort);

    final startIndex = _resolveStartIndex(filtered, request.options.cursor);
    final limit = request.options.limit;
    final endIndex = startIndex >= filtered.length
        ? filtered.length
        : min(startIndex + limit, filtered.length);
    final slice = filtered.sublist(startIndex, endIndex);
    final nextCursor =
        endIndex < filtered.length && slice.isNotEmpty ? slice.last.id : null;
    final totalCount =
        request.options.includeTotalCount ? filtered.length : null;

    return ListRecordsResponse(
      records: slice,
      nextCursor: nextCursor,
      totalCount: totalCount,
    );
  }

  @override
  Future<DataRecord> update(UpdateRecordRequest request) async {
    final existing = await storage.readRecord(
      request.collection,
      request.id,
    );
    if (existing == null) {
      throw RpcDataError.notFound(
        'Record ${request.id} not found in ${request.collection}',
      );
    }

    if (existing.version != request.expectedVersion) {
      throw RpcDataError.conflict(
        'Expected version ${request.expectedVersion}, got ${existing.version}',
      );
    }

    final updated = existing.copyWith(
      payload: request.payload,
      version: existing.version + 1,
      updatedAt: _clock(),
    );
    await storage.writeRecord(updated);
    _recordEvent(DataChangeType.updated, updated);
    return updated;
  }

  @override
  Future<DataRecord> patch(PatchRecordRequest request) async {
    final existing = await storage.readRecord(
      request.collection,
      request.id,
    );
    if (existing == null) {
      throw RpcDataError.notFound(
        'Record ${request.id} not found in ${request.collection}',
      );
    }

    if (existing.version != request.expectedVersion) {
      throw RpcDataError.conflict(
        'Expected version ${request.expectedVersion}, got ${existing.version}',
      );
    }

    final newPayload = request.patch.apply(existing.payload);
    final updated = existing.copyWith(
      payload: newPayload,
      version: existing.version + 1,
      updatedAt: _clock(),
    );
    await storage.writeRecord(updated);
    _recordEvent(DataChangeType.patched, updated);
    return updated;
  }

  @override
  Future<bool> delete(DeleteRecordRequest request) async {
    final existing = await storage.readRecord(
      request.collection,
      request.id,
    );
    if (existing == null) {
      return false;
    }

    if (request.expectedVersion != null &&
        existing.version != request.expectedVersion) {
      throw RpcDataError.conflict(
        'Expected version ${request.expectedVersion}, got ${existing.version}',
      );
    }

    final removed = await storage.deleteRecord(request.collection, request.id);
    if (removed) {
      _recordDeletion(
        request.collection,
        request.id,
        existing.version + 1,
      );
    }
    return removed;
  }

  @override
  Future<bool> deleteCollection(DeleteCollectionRequest request) async {
    final existingRecords = await storage.readCollection(request.collection);
    final removed = await storage.deleteCollection(request.collection);
    if (!removed) {
      return false;
    }

    final history = _history(request.collection);
    history.clear();

    for (final record in existingRecords) {
      _recordDeletion(
        request.collection,
        record.id,
        record.version + 1,
      );
    }

    return true;
  }

  @override
  Future<List<DataRecord>> bulkUpsert(BulkUpsertRequest request) async {
    final results = <DataRecord>[];
    for (final incoming in request.records) {
      final existing =
          await storage.readRecord(incoming.collection, incoming.id);
      if (existing == null) {
        await storage.writeRecord(incoming);
        _recordEvent(DataChangeType.created, incoming);
        results.add(incoming);
        continue;
      }

      if (incoming.version <= existing.version) {
        throw RpcDataError.conflict(
          'Version ${incoming.version} is not newer than ${existing.version} for ${incoming.id}',
        );
      }

      final updated = DataRecord(
        id: existing.id,
        collection: existing.collection,
        payload: incoming.payload,
        version: incoming.version,
        createdAt: existing.createdAt,
        updatedAt: incoming.updatedAt,
      );
      await storage.writeRecord(updated);
      _recordEvent(DataChangeType.updated, updated);
      results.add(updated);
    }
    return results;
  }

  @override
  Future<int> bulkDelete(BulkDeleteRequest request) async {
    final existing = <String, DataRecord>{};
    for (final id in request.ids) {
      final record = await storage.readRecord(request.collection, id);
      if (record != null) {
        existing[id] = record;
      }
    }

    final removed = await storage.deleteRecords(
      request.collection,
      request.ids,
    );

    for (final entry in existing.entries) {
      _recordDeletion(
        request.collection,
        entry.key,
        entry.value.version + 1,
      );
    }

    return removed;
  }

  @override
  Future<ExportSnapshotResponse> exportSnapshot(
    ExportSnapshotRequest request,
  ) async {
    final collection = await storage.readCollection(request.collection);
    return ExportSnapshotResponse(
      records: collection,
      generatedAt: _clock(),
    );
  }

  @override
  Future<ExportDatabaseResponse> exportDatabase(
    ExportDatabaseRequest request,
  ) async {
    final generatedAt = _clock();
    final collections = await storage.listCollections();
    final snapshotCollections = <String, List<DataRecord>>{};
    var recordCount = 0;

    for (final collection in collections) {
      final records = await storage.readCollection(collection);
      snapshotCollections[collection] = records;
      recordCount += records.length;
    }

    final snapshot = _serializeSnapshot(snapshotCollections, generatedAt);

    return ExportDatabaseResponse(
      payload: jsonEncode(snapshot),
      generatedAt: generatedAt,
      formatVersion: _databaseFormatVersion,
      collectionCount: collections.length,
      recordCount: recordCount,
    );
  }

  @override
  Future<ImportDatabaseResponse> importDatabase(
    ImportDatabaseRequest request,
  ) async {
    final snapshot = _decodeSnapshotPayload(request);
    final formatVersion = snapshot['formatVersion'] as String?;
    if (formatVersion != null && formatVersion != _databaseFormatVersion) {
      throw RpcDataError.invalidArgument(
        'Unsupported snapshot format "$formatVersion"',
      );
    }

    final collections = _parseSnapshotCollections(snapshot);
    final replaceExisting = request.replaceExisting;

    final existingCollections = await storage.listCollections();
    final existingRecords = <String, Map<String, DataRecord>>{};
    if (replaceExisting) {
      for (final collection in existingCollections) {
        final records = await storage.readCollection(collection);
        existingRecords[collection] = {
          for (final record in records) record.id: record,
        };
      }
    }

    if (replaceExisting) {
      for (final collection in existingCollections) {
        if (!collections.containsKey(collection)) {
          final previous = existingRecords[collection];
          if (previous != null) {
            for (final record in previous.values) {
              _recordDeletion(collection, record.id, record.version + 1);
            }
          }
          await storage.deleteCollection(collection);
        }
      }
    }

    var importedRecords = 0;
    for (final entry in collections.entries) {
      final collection = entry.key;
      final records = entry.value;

      if (replaceExisting) {
        final previous = existingRecords[collection];
        if (previous != null && previous.isNotEmpty) {
          for (final record in previous.values) {
            _recordDeletion(collection, record.id, record.version + 1);
          }
          await storage.deleteCollection(collection);
        }
      }

      if (records.isNotEmpty) {
        await storage.writeRecords(records);
        for (final record in records) {
          _recordEvent(DataChangeType.snapshot, record);
        }
        importedRecords += records.length;
      }
    }

    return ImportDatabaseResponse(
      collectionCount: collections.length,
      recordCount: importedRecords,
      appliedAt: _clock(),
    );
  }

  @override
  Future<SearchRecordsResponse> search(
    SearchRecordsRequest request,
  ) async {
    final collection = await storage.readCollection(request.collection);
    final filtered = _filterAndSort(collection, request.filter, null);
    final query = request.query.toLowerCase();
    final hits = filtered.where((record) {
      final text = record.payload.values
          .map((value) => value.toString().toLowerCase())
          .join(' ');
      return text.contains(query);
    }).toList(growable: false);

    final startIndex = _resolveStartIndex(hits, request.options.cursor);
    final limit = request.options.limit;
    final endIndex = startIndex >= hits.length
        ? hits.length
        : min(startIndex + limit, hits.length);
    final slice = hits.sublist(startIndex, endIndex);
    final nextCursor =
        endIndex < hits.length && slice.isNotEmpty ? slice.last.id : null;

    return SearchRecordsResponse(
      records: slice,
      totalHits: hits.length,
      nextCursor: nextCursor,
    );
  }

  @override
  Future<AggregateMetricsResponse> aggregate(
    AggregateMetricsRequest request,
  ) async {
    final collection = await storage.readCollection(request.collection);
    final filtered = _filterAndSort(collection, request.filter, null);
    final metrics = <String, num>{};

    for (final entry in request.metrics.entries) {
      final metricName = entry.key;
      final definition = entry.value;
      if (definition == 'count') {
        metrics[metricName] = filtered.length;
        continue;
      }

      final parts = definition.split(':');
      if (parts.length != 2) {
        throw RpcDataError.invalidArgument(
          'Unsupported metric definition "$definition"',
        );
      }
      final op = parts[0];
      final field = parts[1];
      final values = filtered
          .map((record) => _getFieldValue(record, field))
          .whereType<num>()
          .toList(growable: false);

      switch (op) {
        case 'sum':
          metrics[metricName] =
              values.fold<num>(0, (prev, element) => prev + element);
          break;
        case 'avg':
          metrics[metricName] = values.isEmpty
              ? 0
              : values.reduce((a, b) => a + b) / values.length;
          break;
        case 'min':
          metrics[metricName] = values.isEmpty ? 0 : values.reduce(min);
          break;
        case 'max':
          metrics[metricName] = values.isEmpty ? 0 : values.reduce(max);
          break;
        default:
          throw RpcDataError.invalidArgument(
            'Unknown aggregate operation "$op"',
          );
      }
    }

    return AggregateMetricsResponse(metrics: metrics);
  }

  @override
  Stream<DataChangeEvent> watch(
    WatchChangesRequest request,
  ) {
    final history = _history(request.collection);
    final startIndex = () {
      if (request.cursor == null) {
        return 0;
      }
      final index =
          history.indexWhere((event) => event.cursor == request.cursor);
      if (index == -1) {
        throw RpcDataError.invalidArgument(
          'Cursor ${request.cursor} is not known for ${request.collection}',
        );
      }
      return index + 1;
    }();

    return Stream<DataChangeEvent>.multi((listener) {
      for (final event in history.skip(startIndex)) {
        listener.add(event);
      }

      final subscription = _changeController.stream
          .where((event) => event.collection == request.collection)
          .listen(listener.add,
              onError: listener.addError, onDone: listener.close);

      listener.onCancel = () async {
        await subscription.cancel();
      };
    });
  }

  Future<DataRecord?> _fetchConflictRecord(
    DataCommand command,
  ) async {
    switch (command.type) {
      case DataCommandType.create:
        final request = CreateRecordRequest.fromJson(command.payload);
        if (request.id == null) {
          return null;
        }
        return get(
          GetRecordRequest(collection: request.collection, id: request.id!),
        );
      case DataCommandType.update:
        final request = UpdateRecordRequest.fromJson(command.payload);
        return get(
          GetRecordRequest(
            collection: request.collection,
            id: request.id,
          ),
        );
      case DataCommandType.patch:
        final request = PatchRecordRequest.fromJson(command.payload);
        return get(
          GetRecordRequest(collection: request.collection, id: request.id),
        );
      case DataCommandType.delete:
        final request = DeleteRecordRequest.fromJson(command.payload);
        return get(
          GetRecordRequest(collection: request.collection, id: request.id),
        );
    }
  }

  Future<SyncChangeResponse> _applyCommand(
    SyncChangeRequest message,
  ) async {
    final command = message.command;
    switch (command.type) {
      case DataCommandType.create:
        final request = CreateRecordRequest.fromJson(command.payload);
        final record = await create(request);
        return SyncChangeResponse(
          requestId: message.requestId,
          commandId: command.commandId,
          applied: true,
          record: record,
        );
      case DataCommandType.update:
        final request = UpdateRecordRequest.fromJson(command.payload);
        final record = await update(request);
        return SyncChangeResponse(
          requestId: message.requestId,
          commandId: command.commandId,
          applied: true,
          record: record,
        );
      case DataCommandType.patch:
        final request = PatchRecordRequest.fromJson(command.payload);
        final record = await patch(request);
        return SyncChangeResponse(
          requestId: message.requestId,
          commandId: command.commandId,
          applied: true,
          record: record,
        );
      case DataCommandType.delete:
        final request = DeleteRecordRequest.fromJson(command.payload);
        final removed = await delete(request);
        if (!removed) {
          // Отсутствие записи не считаем ошибкой — команда идемпотентна.
          return SyncChangeResponse(
            requestId: message.requestId,
            commandId: command.commandId,
            applied: true,
          );
        }
        return SyncChangeResponse(
          requestId: message.requestId,
          commandId: command.commandId,
          applied: true,
        );
    }
  }

  @override
  Stream<SyncChangeResponse> sync(
    Stream<SyncChangeRequest> requests,
  ) async* {
    await for (final message in requests) {
      try {
        final response = await _applyCommand(message);
        yield response;
      } on RpcDataError catch (error) {
        final conflict = await _fetchConflictRecord(message.command);
        yield SyncChangeResponse(
          requestId: message.requestId,
          commandId: message.command.commandId,
          applied: false,
          conflict: conflict,
          error: error.message,
        );
        if (!message.resolveConflicts) {
          rethrow;
        }
      }
    }
  }

  @override
  Future<void> dispose() async {
    await _changeController.close();
    await storage.dispose();
  }
}

/// In-memory адаптер, реализующий интерфейс `DataStorageAdapter` на обычных
/// картах. Эту реализацию легко заменить на SQLite/Isar/Hive, не меняя
/// бизнес-логику `BaseDataRepository`.
final class InMemoryStorageAdapter implements DataStorageAdapter {
  final Map<String, Map<String, DataRecord>> _storage = {};

  Map<String, DataRecord> _collection(String collection) {
    return _storage.putIfAbsent(collection, () => <String, DataRecord>{});
  }

  @override
  Future<DataRecord?> readRecord(String collection, String id) async {
    final store = _collection(collection);
    return store[id];
  }

  @override
  Future<List<DataRecord>> readCollection(String collection) async {
    final store = _collection(collection);
    return store.values.toList(growable: false);
  }

  @override
  Future<List<String>> listCollections() async {
    return _storage.keys.toList(growable: false);
  }

  @override
  Future<void> writeRecord(DataRecord record) async {
    final store = _collection(record.collection);
    store[record.id] = record;
  }

  @override
  Future<void> writeRecords(Iterable<DataRecord> records) async {
    for (final record in records) {
      final store = _collection(record.collection);
      store[record.id] = record;
    }
  }

  @override
  Future<bool> deleteRecord(String collection, String id) async {
    final store = _collection(collection);
    return store.remove(id) != null;
  }

  @override
  Future<int> deleteRecords(
    String collection,
    Iterable<String> ids,
  ) async {
    final store = _collection(collection);
    var removed = 0;
    for (final id in ids) {
      if (store.remove(id) != null) {
        removed++;
      }
    }
    return removed;
  }

  @override
  Future<bool> deleteCollection(String collection) async {
    return _storage.remove(collection) != null;
  }

  @override
  Future<void> dispose() async {
    _storage.clear();
  }
}

/// Готовый in-memory репозиторий, который можно заменить адаптером к SQLite
/// или любому другому backend-у, не меняя остальной код сервиса данных.
final class InMemoryDataRepository extends BaseDataRepository {
  InMemoryDataRepository({
    InMemoryStorageAdapter? storage,
    DateTime Function()? clock,
    String Function(String collection)? idGenerator,
  }) : super(
          storage ?? InMemoryStorageAdapter(),
          clock: clock,
          idGenerator: idGenerator,
        );
}
