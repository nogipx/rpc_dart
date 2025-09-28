import 'dart:async';
import 'dart:math';

import 'package:collection/collection.dart';

import 'data_contract.dart';
import 'models.dart';

/// Абстракция репозитория данных.
abstract interface class DataRepository {
  Future<DataRecord> create(String tenantId, CreateRecordRequest request);

  Future<DataRecord?> get(String tenantId, GetRecordRequest request);

  Future<ListRecordsResponse> list(String tenantId, ListRecordsRequest request);

  Future<DataRecord> update(String tenantId, UpdateRecordRequest request);

  Future<DataRecord> patch(String tenantId, PatchRecordRequest request);

  Future<bool> delete(String tenantId, DeleteRecordRequest request);

  Future<List<DataRecord>> bulkUpsert(
    String tenantId,
    BulkUpsertRequest request,
  );

  Future<int> bulkDelete(String tenantId, BulkDeleteRequest request);

  Future<ExportSnapshotResponse> exportSnapshot(
    String tenantId,
    ExportSnapshotRequest request,
  );

  Future<SearchRecordsResponse> search(
    String tenantId,
    SearchRecordsRequest request,
  );

  Future<AggregateMetricsResponse> aggregate(
    String tenantId,
    AggregateMetricsRequest request,
  );

  Stream<DataChangeEvent> watch(
    String tenantId,
    WatchChangesRequest request,
  );

  Stream<SyncChangeResponse> sync(
    String tenantId,
    Stream<SyncChangeRequest> requests,
  );

  Future<void> dispose();
}

final class _RecordedEvent {
  _RecordedEvent(this.tenantId, this.event);

  final String tenantId;
  final DataChangeEvent event;
}

/// Простая in-memory реализация с оптимистической конкуренцией.
final class InMemoryDataRepository implements DataRepository {
  final Map<String, Map<String, Map<String, DataRecord>>> _storage = {};
  final Map<String, List<DataChangeEvent>> _eventJournal = {};
  final StreamController<_RecordedEvent> _changeController =
      StreamController<_RecordedEvent>.broadcast();
  final Random _random = Random();

  int _cursorSequence = 0;
  int _idSequence = 0;

  Map<String, DataRecord> _collection(
    String tenantId,
    String collection,
  ) {
    final tenantStore =
        _storage.putIfAbsent(tenantId, () => <String, Map<String, DataRecord>>{});
    return tenantStore.putIfAbsent(collection, () => <String, DataRecord>{});
  }

  List<DataChangeEvent> _history(String tenantId, String collection) {
    final key = _eventKey(tenantId, collection);
    return _eventJournal.putIfAbsent(key, () => <DataChangeEvent>[]);
  }

  String _eventKey(String tenantId, String collection) => '$tenantId::$collection';

  String _generateId(String collection) {
    final suffix = _random.nextInt(1 << 32).toRadixString(16);
    final sequence = _idSequence++;
    return '$collection-$sequence-$suffix';
  }

  DataChangeEvent _recordEvent(
    String tenantId,
    DataChangeType type,
    DataRecord? record,
  ) {
    final cursor = (++_cursorSequence).toString();
    final occurredAt = DateTime.now().toUtc();
    final event = DataChangeEvent(
      type: type,
      collection: record?.collection ?? '<unknown>',
      id: record?.id ?? '<unknown>',
      record: record,
      version: record?.version ?? 0,
      cursor: cursor,
      occurredAt: occurredAt,
    );
    final history = _history(tenantId, event.collection);
    history.add(event);
    _changeController.add(_RecordedEvent(tenantId, event));
    return event;
  }

  DataChangeEvent _recordDeletion(
    String tenantId,
    String collection,
    String id,
    int version,
  ) {
    final cursor = (++_cursorSequence).toString();
    final occurredAt = DateTime.now().toUtc();
    final event = DataChangeEvent(
      type: DataChangeType.deleted,
      collection: collection,
      id: id,
      record: null,
      version: version,
      cursor: cursor,
      occurredAt: occurredAt,
    );
    final history = _history(tenantId, collection);
    history.add(event);
    _changeController.add(_RecordedEvent(tenantId, event));
    return event;
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
        final cmp = value.compareTo(constraint.min!);
        if (cmp < 0 || (cmp == 0 && !constraint.includeMin)) {
          return false;
        }
      }
      if (constraint.max != null) {
        final cmp = value.compareTo(constraint.max!);
        if (cmp > 0 || (cmp == 0 && !constraint.includeMax)) {
          return false;
        }
      }
    }

    if (filter.containsTerms.isNotEmpty) {
      final payloadString = record.payload.values
          .whereType<String>()
          .map((value) => value.toLowerCase())
          .join(' ');
      for (final term in filter.containsTerms) {
        if (!payloadString.contains(term.toLowerCase())) {
          return false;
        }
      }
    }

    return true;
  }

  Object? _getFieldValue(DataRecord record, String field) {
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

  int _compare(DataRecord a, DataRecord b, SortOrder? sort) {
    if (sort == null) {
      return a.id.compareTo(b.id);
    }

    final valueA = _getFieldValue(a, sort.field);
    final valueB = _getFieldValue(b, sort.field);

    int result;
    if (valueA is Comparable && valueB is Comparable) {
      result = valueA.compareTo(valueB as Comparable);
    } else {
      result = valueA.toString().compareTo(valueB.toString());
    }

    return sort.descending ? -result : result;
  }

  List<DataRecord> _filterAndSort(
    Map<String, DataRecord> collection,
    RecordFilter? filter,
    SortOrder? sort,
  ) {
    final filtered = collection.values
        .where((record) => _matchesFilter(record, filter))
        .toList();
    filtered.sort((a, b) => _compare(a, b, sort));
    return filtered;
  }

  @override
  Future<DataRecord> create(String tenantId, CreateRecordRequest request) async {
    final collection = _collection(tenantId, request.collection);
    final now = DateTime.now().toUtc();
    final id = request.id ?? _generateId(request.collection);

    if (collection.containsKey(id)) {
      throw RpcError.conflict(
        'Record with id "$id" already exists in ${request.collection}',
      );
    }

    final record = DataRecord(
      id: id,
      collection: request.collection,
      payload: request.payload,
      version: 1,
      createdAt: now,
      updatedAt: now,
    );
    collection[id] = record;
    _recordEvent(tenantId, DataChangeType.created, record);
    return record;
  }

  @override
  Future<DataRecord?> get(String tenantId, GetRecordRequest request) async {
    final collection = _collection(tenantId, request.collection);
    return collection[request.id];
  }

  @override
  Future<ListRecordsResponse> list(
    String tenantId,
    ListRecordsRequest request,
  ) async {
    final collection = _collection(tenantId, request.collection);
    final filtered = _filterAndSort(collection, request.filter, request.sort);

    int startIndex = 0;
    if (request.options.cursor != null) {
      final index = filtered.indexWhere((record) => record.id == request.options.cursor);
      if (index >= 0) {
        startIndex = index + 1;
      }
    }

    final endIndex = (startIndex + request.options.limit).clamp(0, filtered.length);
    final slice = filtered.sublist(startIndex, endIndex);
    final nextCursor = endIndex < filtered.length ? filtered[endIndex - 1].id : null;
    final totalCount = request.options.includeTotalCount ? filtered.length : null;

    return ListRecordsResponse(
      records: slice,
      nextCursor: nextCursor,
      totalCount: totalCount,
    );
  }

  @override
  Future<DataRecord> update(String tenantId, UpdateRecordRequest request) async {
    final collection = _collection(tenantId, request.record.collection);
    final existing = collection[request.record.id];
    if (existing == null) {
      throw RpcError.notFound(
        'Record ${request.record.id} not found in ${request.record.collection}',
      );
    }

    if (request.record.version <= existing.version) {
      throw RpcError.conflict(
        'Version ${request.record.version} is not newer than ${existing.version}',
      );
    }

    final updated = request.record.copyWith(updatedAt: DateTime.now().toUtc());
    collection[updated.id] = updated;
    _recordEvent(tenantId, DataChangeType.updated, updated);
    return updated;
  }

  @override
  Future<DataRecord> patch(String tenantId, PatchRecordRequest request) async {
    final collection = _collection(tenantId, request.collection);
    final existing = collection[request.id];
    if (existing == null) {
      throw RpcError.notFound(
        'Record ${request.id} not found in ${request.collection}',
      );
    }

    if (existing.version != request.expectedVersion) {
      throw RpcError.conflict(
        'Expected version ${request.expectedVersion}, got ${existing.version}',
      );
    }

    final newPayload = request.patch.apply(existing.payload);
    final updated = existing.copyWith(
      payload: newPayload,
      version: existing.version + 1,
      updatedAt: DateTime.now().toUtc(),
    );
    collection[updated.id] = updated;
    _recordEvent(tenantId, DataChangeType.patched, updated);
    return updated;
  }

  @override
  Future<bool> delete(String tenantId, DeleteRecordRequest request) async {
    final collection = _collection(tenantId, request.collection);
    final existing = collection[request.id];
    if (existing == null) {
      return false;
    }

    if (request.expectedVersion != null && existing.version != request.expectedVersion) {
      throw RpcError.conflict(
        'Expected version ${request.expectedVersion}, got ${existing.version}',
      );
    }

    collection.remove(request.id);
    _recordDeletion(tenantId, request.collection, request.id, existing.version + 1);
    return true;
  }

  @override
  Future<List<DataRecord>> bulkUpsert(
    String tenantId,
    BulkUpsertRequest request,
  ) async {
    final results = <DataRecord>[];
    for (final record in request.records) {
      final collection = _collection(tenantId, record.collection);
      final existing = collection[record.id];
      if (existing == null) {
        final created = await create(
          tenantId,
          CreateRecordRequest(
            collection: record.collection,
            payload: record.payload,
            id: record.id,
          ),
        );
        results.add(created);
      } else {
        if (record.version <= existing.version) {
          throw RpcError.conflict(
            'Version ${record.version} is not newer than ${existing.version} for ${record.id}',
          );
        }
        final updated = record.copyWith(updatedAt: DateTime.now().toUtc());
        collection[record.id] = updated;
        _recordEvent(tenantId, DataChangeType.updated, updated);
        results.add(updated);
      }
    }
    return results;
  }

  @override
  Future<int> bulkDelete(String tenantId, BulkDeleteRequest request) async {
    final collection = _collection(tenantId, request.collection);
    var count = 0;
    for (final id in request.ids) {
      final existing = collection.remove(id);
      if (existing != null) {
        count++;
        _recordDeletion(tenantId, request.collection, id, existing.version + 1);
      }
    }
    return count;
  }

  @override
  Future<ExportSnapshotResponse> exportSnapshot(
    String tenantId,
    ExportSnapshotRequest request,
  ) async {
    final collection = _collection(tenantId, request.collection);
    final records = collection.values.toList(growable: false);
    return ExportSnapshotResponse(
      records: records,
      generatedAt: DateTime.now().toUtc(),
    );
  }

  @override
  Future<SearchRecordsResponse> search(
    String tenantId,
    SearchRecordsRequest request,
  ) async {
    final collection = _collection(tenantId, request.collection);
    final filtered = _filterAndSort(collection, request.filter, null);
    final query = request.query.toLowerCase();
    final hits = filtered.where((record) {
      final text = record.payload.values
          .map((value) => value.toString().toLowerCase())
          .join(' ');
      return text.contains(query);
    }).toList();

    final limit = request.options.limit;
    final slice = hits.take(limit).toList(growable: false);
    final nextCursor = slice.length == limit ? slice.last.id : null;

    return SearchRecordsResponse(
      records: slice,
      totalHits: hits.length,
      nextCursor: nextCursor,
    );
  }

  @override
  Future<AggregateMetricsResponse> aggregate(
    String tenantId,
    AggregateMetricsRequest request,
  ) async {
    final collection = _collection(tenantId, request.collection);
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
        throw RpcError.invalidArgument(
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
          metrics[metricName] = values.fold<num>(0, (sum, value) => sum + value);
          break;
        case 'avg':
          final total = values.fold<num>(0, (sum, value) => sum + value);
          metrics[metricName] = values.isEmpty ? 0 : total / values.length;
          break;
        case 'min':
          metrics[metricName] = values.isEmpty ? 0 : values.reduce(min);
          break;
        case 'max':
          metrics[metricName] = values.isEmpty ? 0 : values.reduce(max);
          break;
        default:
          throw RpcError.invalidArgument(
            'Unsupported aggregate operator "$op"',
          );
      }
    }

    return AggregateMetricsResponse(metrics: metrics);
  }

  @override
  Stream<DataChangeEvent> watch(String tenantId, WatchChangesRequest request) {
    final history = List<DataChangeEvent>.from(
      _history(tenantId, request.collection),
    );

    final startIndex = () {
      if (request.cursor == null) {
        return 0;
      }
      final index = history.indexWhere((event) => event.cursor == request.cursor);
      if (index == -1) {
        throw RpcError.invalidArgument(
          'Cursor ${request.cursor} is not known for ${request.collection}',
        );
      }
      return index + 1;
    }();

    return Stream<DataChangeEvent>.multi((listener) {
      for (final event in history.skip(startIndex)) {
        listener.add(event);
      }

      final subscription = _changeController.stream.listen((recorded) {
        if (recorded.tenantId == tenantId &&
            recorded.event.collection == request.collection) {
          listener.add(recorded.event);
        }
      }, onError: listener.addError, onDone: listener.close);

      listener.onCancel = () async {
        await subscription.cancel();
      };
    });
  }

  @override
  Stream<SyncChangeResponse> sync(
    String tenantId,
    Stream<SyncChangeRequest> requests,
  ) async* {
    await for (final message in requests) {
      try {
        await _applySyncEvent(tenantId, message.event);
        yield SyncChangeResponse(
          requestId: message.requestId,
          applied: true,
        );
      } on RpcError catch (error) {
        final conflictRecord = await get(
          tenantId,
          GetRecordRequest(
            collection: message.event.collection,
            id: message.event.id,
          ),
        );
        yield SyncChangeResponse(
          requestId: message.requestId,
          applied: false,
          conflict: conflictRecord,
        );
        if (!message.resolveConflicts) {
          rethrow;
        }
      }
    }
  }

  Future<void> _applySyncEvent(
    String tenantId,
    DataChangeEvent event,
  ) async {
    switch (event.type) {
      case DataChangeType.created:
        final payload = event.record?.payload ?? const <String, dynamic>{};
        await create(
          tenantId,
          CreateRecordRequest(
            collection: event.collection,
            payload: payload,
            id: event.id,
          ),
        );
        break;
      case DataChangeType.updated:
        final record = event.record;
        if (record == null) {
          throw RpcError.invalidArgument('Sync update requires record payload');
        }
        await update(
          tenantId,
          UpdateRecordRequest(record: record),
        );
        break;
      case DataChangeType.patched:
        final record = event.record;
        if (record == null) {
          throw RpcError.invalidArgument('Sync patch requires record payload');
        }
        await patch(
          tenantId,
          PatchRecordRequest(
            collection: record.collection,
            id: record.id,
            expectedVersion: record.version - 1,
            patch: RecordPatch(set: record.payload),
          ),
        );
        break;
      case DataChangeType.deleted:
        await delete(
          tenantId,
          DeleteRecordRequest(
            collection: event.collection,
            id: event.id,
          ),
        );
        break;
      case DataChangeType.snapshot:
        // Snapshot events are informational for initial sync.
        break;
    }
  }

  @override
  Future<void> dispose() async {
    await _changeController.close();
  }
}
