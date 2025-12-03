part of '_index.dart';

/// In-memory адаптер, реализующий интерфейс `DataStorageAdapter` на обычных
/// картах. Эту реализацию легко заменить на SQLite/Isar/Hive, не меняя
/// бизнес-логику `BaseDataRepository`.
class InMemoryStorageAdapter implements IDataStorageAdapter {
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
  Future<Map<String, DataRecord>> readRecords(
    String collection,
    Iterable<String> ids,
  ) async {
    final store = _collection(collection);
    final result = <String, DataRecord>{};
    for (final id in ids) {
      final record = store[id];
      if (record != null) {
        result[id] = record;
      }
    }
    return result;
  }

  @override
  Future<List<DataRecord>> readCollection(String collection) async {
    final store = _collection(collection);
    return store.values.toList(growable: false);
  }

  @override
  Stream<List<DataRecord>> readCollectionChunks(
    String collection, {
    int chunkSize = BaseDataRepository.databaseExportChunkSize,
  }) async* {
    final store = _collection(collection);
    if (store.isEmpty) {
      return;
    }
    final entries = List<DataRecord>.from(store.values, growable: false);
    final effectiveChunkSize = chunkSize <= 0
        ? entries.length
        : max(1, chunkSize);
    for (
      var offset = 0;
      offset < entries.length;
      offset += effectiveChunkSize
    ) {
      final end = min(offset + effectiveChunkSize, entries.length);
      yield entries.sublist(offset, end);
    }
  }

  @override
  Future<ListRecordsResponse> queryCollection(
    ListRecordsRequest request,
  ) async {
    final collection = await readCollection(request.collection);
    final filtered = _filterAndSortRecords(
      collection,
      request.filter,
      request.sort,
    );
    final cursorIndex = _resolveCursorStart(filtered, request.options.cursor);
    final baseIndex = cursorIndex + request.options.offset;
    final startIndex = min(filtered.length, max(0, baseIndex));
    final endIndex = min(startIndex + request.options.limit, filtered.length);
    final slice = filtered.sublist(startIndex, endIndex);
    final nextCursor = slice.isNotEmpty ? slice.last.id : null;
    final totalCount = request.options.includeTotalCount
        ? filtered.length
        : null;

    return ListRecordsResponse(
      records: slice,
      nextCursor: nextCursor,
      totalCount: totalCount,
    );
  }

  @override
  Future<List<String>> listCollections() async {
    return _storage.keys.toList(growable: false);
  }

  @override
  Future<SearchRecordsResponse> searchCollection(
    SearchRecordsRequest request,
  ) async {
    final collection = await readCollection(request.collection);
    final filtered = _filterAndSortRecords(collection, request.filter, null);
    final query = request.query.toLowerCase();
    final hits = filtered
        .where((record) {
          final text = record.payload.values
              .map((value) => value.toString().toLowerCase())
              .join(' ');
          return text.contains(query);
        })
        .toList(growable: false);

    final cursorIndex = _resolveCursorStart(hits, request.options.cursor);
    final baseIndex = cursorIndex + request.options.offset;
    final startIndex = min(hits.length, max(0, baseIndex));
    final endIndex = min(startIndex + request.options.limit, hits.length);
    final slice = hits.sublist(startIndex, endIndex);
    final nextCursor = endIndex < hits.length && slice.isNotEmpty
        ? slice.last.id
        : null;

    return SearchRecordsResponse(
      records: slice,
      totalHits: hits.length,
      nextCursor: nextCursor,
    );
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
  Future<bool> deleteRecord(
    String collection,
    String id, {
    int? expectedVersion,
  }) async {
    final store = _collection(collection);
    final existing = store[id];
    if (existing == null) {
      return false;
    }
    if (expectedVersion != null && existing.version != expectedVersion) {
      throw RpcDataError.conflict(
        'Expected version $expectedVersion, got ${existing.version}',
      );
    }
    return store.remove(id) != null;
  }

  @override
  Future<int> deleteRecords(String collection, Iterable<String> ids) async {
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

  @override
  Future<AggregateMetricsResponse> aggregateCollection(
    AggregateMetricsRequest request,
  ) async {
    _validateAggregateMetrics(request);
    final collection = await readCollection(request.collection);
    final filtered = _filterAndSortRecords(collection, request.filter, null);
    final metrics = _computeAggregates(filtered, request.metrics);
    return AggregateMetricsResponse(metrics: metrics);
  }
}

List<DataRecord> _filterAndSortRecords(
  Iterable<DataRecord> records,
  RecordFilter? filter,
  SortOrder? sort,
) {
  final filtered = records
      .where((record) => _recordMatchesFilter(record, filter))
      .toList();
  filtered.sort((a, b) => _compareRecords(a, b, sort));
  return filtered;
}

int _resolveCursorStart(List<DataRecord> records, String? cursor) {
  if (cursor == null) {
    return 0;
  }
  final index = records.indexWhere((record) => record.id == cursor);
  if (index == -1) {
    throw RpcDataError.invalidArgument(
      'Cursor $cursor is not valid for selection',
    );
  }
  return index + 1;
}

Map<String, num> _computeAggregates(
  Iterable<DataRecord> records,
  Map<String, String> metrics,
) {
  final result = <String, num>{};
  final entries = records.toList(growable: false);

  for (final entry in metrics.entries) {
    final definition = entry.value;
    if (definition == 'count') {
      result[entry.key] = entries.length;
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
    final values = entries
        .map((record) => _recordFieldValue(record, field))
        .whereType<num>()
        .toList(growable: false);

    switch (op) {
      case 'sum':
        result[entry.key] = values.fold<num>(
          0,
          (previousValue, element) => previousValue + element,
        );
        break;
      case 'avg':
        if (values.isEmpty) {
          result[entry.key] = 0;
        } else {
          final total = values.fold<num>(
            0,
            (previousValue, element) => previousValue + element,
          );
          result[entry.key] = total / values.length;
        }
        break;
      case 'min':
        result[entry.key] = values.isEmpty ? 0 : values.reduce(min);
        break;
      case 'max':
        result[entry.key] = values.isEmpty ? 0 : values.reduce(max);
        break;
      default:
        throw RpcDataError.invalidArgument('Unknown aggregate operation "$op"');
    }
  }

  return result;
}

bool _recordMatchesFilter(DataRecord record, RecordFilter? filter) {
  if (filter == null) {
    return true;
  }

  for (final entry in filter.equals.entries) {
    final value = _recordFieldValue(record, entry.key);
    if (value != entry.value) {
      return false;
    }
  }

  for (final entry in filter.range.entries) {
    final value = _recordFieldValue(record, entry.key);
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
        .map((value) => value.toString().toLowerCase())
        .join(' ');
    for (final term in filter.containsTerms) {
      if (!haystack.contains(term.toLowerCase())) {
        return false;
      }
    }
  }

  return true;
}

int _compareRecords(DataRecord a, DataRecord b, SortOrder? sort) {
  if (sort == null) {
    return a.id.compareTo(b.id);
  }

  final valueA = _recordFieldValue(a, sort.field);
  final valueB = _recordFieldValue(b, sort.field);

  int result;
  if (valueA is Comparable && valueB is Comparable) {
    result = valueA.compareTo(valueB);
  } else {
    result = valueA.toString().compareTo(valueB.toString());
  }

  return sort.descending ? -result : result;
}

dynamic _recordFieldValue(DataRecord record, String field) {
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

void _validateAggregateMetrics(AggregateMetricsRequest request) {
  for (final entry in request.metrics.entries) {
    final definition = entry.value;
    if (definition == 'count') {
      continue;
    }
    final parts = definition.split(':');
    if (parts.length != 2) {
      throw RpcDataError.invalidArgument(
        'Unsupported metric definition "$definition"',
      );
    }
    final op = parts[0];
    switch (op) {
      case 'sum':
      case 'avg':
      case 'min':
      case 'max':
        continue;
      default:
        throw RpcDataError.invalidArgument('Unknown aggregate operation "$op"');
    }
  }
}
