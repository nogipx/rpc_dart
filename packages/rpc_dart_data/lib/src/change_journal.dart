// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:convert';

import 'models.dart';
import 'rpc/data_contract.dart';

/// Persists and replays change events for [DataRepository.watch] cursors.
abstract interface class DataChangeJournal {
  /// Records a change event and returns the materialised [DataChangeEvent]
  /// including the assigned cursor.
  Future<DataChangeEvent> recordChange({
    required DataChangeType type,
    required String collection,
    required String id,
    required int version,
    required DateTime occurredAt,
    DataRecord? record,
  });

  /// Records a deletion event and returns the materialised [DataChangeEvent].
  Future<DataChangeEvent> recordDeletion({
    required String collection,
    required String id,
    required int version,
    required DateTime occurredAt,
  });

  /// Returns the backlog of events for the [collection] after the provided
  /// [cursor]. If [cursor] is `null`, the entire backlog is returned.
  Future<List<DataChangeEvent>> replayCollection(
    String collection, {
    String? afterCursor,
  });

  /// Applies retention rules to the backlog of [collection].
  ///
  /// When [retainAfter] is provided, events older than the timestamp are
  /// removed. When [maxEvents] is provided, only the most recent entries are
  /// kept. Both rules can be combined.
  Future<void> prune({
    required String collection,
    int? maxEvents,
    DateTime? retainAfter,
  });

  /// Removes the backlog for the given [collection].
  Future<void> purgeCollection(String collection);

  /// Releases any resources used by the journal.
  Future<void> dispose();
}

/// In-memory implementation of [DataChangeJournal]. Primarily used by the
/// unit tests and the `InMemoryDataRepository` helper.
final class InMemoryDataChangeJournal implements DataChangeJournal {
  InMemoryDataChangeJournal()
    : _events = <String, List<DataChangeEvent>>{},
      _cursorIndex = <String, Map<String, int>>{};

  final Map<String, List<DataChangeEvent>> _events;
  final Map<String, Map<String, int>> _cursorIndex;
  int _cursorSequence = 0;

  List<DataChangeEvent> _history(String collection) {
    _cursorIndex.putIfAbsent(collection, () => <String, int>{});
    return _events.putIfAbsent(collection, () => <DataChangeEvent>[]);
  }

  String _nextCursor() {
    _cursorSequence += 1;
    return _cursorSequence.toString();
  }

  void _rebuildIndex(String collection) {
    final history = _events[collection];
    if (history == null || history.isEmpty) {
      _cursorIndex[collection] = <String, int>{};
      return;
    }

    final index = <String, int>{};
    for (var i = 0; i < history.length; i += 1) {
      index[history[i].cursor] = i;
    }
    _cursorIndex[collection] = index;
  }

  int _cursorPosition(String collection, String cursor) {
    final index = _cursorIndex[collection]?[cursor];
    if (index == null) {
      return -1;
    }
    final history = _events[collection];
    if (history == null || history.isEmpty) {
      return -1;
    }
    if (index >= history.length || history[index].cursor != cursor) {
      _rebuildIndex(collection);
      return _cursorIndex[collection]?[cursor] ?? -1;
    }
    return index;
  }

  @override
  Future<DataChangeEvent> recordChange({
    required DataChangeType type,
    required String collection,
    required String id,
    required int version,
    required DateTime occurredAt,
    DataRecord? record,
  }) async {
    final event = DataChangeEvent(
      type: type,
      collection: collection,
      id: id,
      record: record,
      version: version,
      cursor: _nextCursor(),
      occurredAt: occurredAt,
    );
    final history = _history(collection);
    history.add(event);
    _cursorIndex[collection]![event.cursor] = history.length - 1;
    return event;
  }

  @override
  Future<DataChangeEvent> recordDeletion({
    required String collection,
    required String id,
    required int version,
    required DateTime occurredAt,
  }) {
    final event = DataChangeEvent(
      type: DataChangeType.deleted,
      collection: collection,
      id: id,
      record: null,
      version: version,
      cursor: _nextCursor(),
      occurredAt: occurredAt,
    );
    final history = _history(collection);
    history.add(event);
    _cursorIndex[collection]![event.cursor] = history.length - 1;
    return Future.value(event);
  }

  @override
  Future<List<DataChangeEvent>> replayCollection(
    String collection, {
    String? afterCursor,
  }) async {
    final history = _history(collection);
    if (afterCursor == null) {
      return List<DataChangeEvent>.from(history);
    }
    final position = _cursorPosition(collection, afterCursor);
    if (position == -1) {
      throw RpcDataError.invalidArgument(
        'Cursor $afterCursor is not known for $collection',
      );
    }
    return history.sublist(position + 1);
  }

  @override
  Future<void> purgeCollection(String collection) async {
    _events.remove(collection);
    _cursorIndex.remove(collection);
  }

  @override
  Future<void> prune({
    required String collection,
    int? maxEvents,
    DateTime? retainAfter,
  }) async {
    final history = _history(collection);
    if (history.isEmpty) {
      return;
    }
    if (retainAfter != null) {
      history.removeWhere((event) => event.occurredAt.isBefore(retainAfter));
    }
    if (maxEvents != null && maxEvents > 0 && history.length > maxEvents) {
      history.removeRange(0, history.length - maxEvents);
    }

    _rebuildIndex(collection);
  }

  @override
  Future<void> dispose() async {
    _events.clear();
    _cursorIndex.clear();
  }
}

String? encodeRecordPayload(DataRecord? record) {
  if (record == null) {
    return null;
  }
  return jsonEncode(record.toJson());
}

DataRecord? decodeRecordPayload(String? payload) {
  if (payload == null) {
    return null;
  }
  final decoded = jsonDecode(payload);
  if (decoded is! Map<String, dynamic>) {
    throw StateError('Invalid record payload stored in change journal');
  }
  return DataRecord.fromJson(decoded);
}

/// Simple guard that validates a change cursor string can be interpreted as an
/// integer sequence value. Persistent journals use monotonically increasing
/// integers for ordering, so the helper is shared between implementations.
int parseCursor(String cursor) {
  final sequence = int.tryParse(cursor);
  if (sequence == null || sequence <= 0) {
    throw RpcDataError.invalidArgument('Cursor $cursor is not valid.');
  }
  return sequence;
}
