// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:convert';

import 'data_contract.dart';
import 'models.dart';

/// Persists and replays change events for [DataRepository.watch] and
/// `syncChanges` cursors.
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

  /// Removes the backlog for the given [collection].
  Future<void> purgeCollection(String collection);

  /// Releases any resources used by the journal.
  Future<void> dispose();
}

/// In-memory implementation of [DataChangeJournal]. Primarily used by the
/// unit tests and the `InMemoryDataRepository` helper.
final class InMemoryDataChangeJournal implements DataChangeJournal {
  InMemoryDataChangeJournal() : _events = <String, List<DataChangeEvent>>{};

  final Map<String, List<DataChangeEvent>> _events;
  int _cursorSequence = 0;

  List<DataChangeEvent> _history(String collection) {
    return _events.putIfAbsent(collection, () => <DataChangeEvent>[]);
  }

  String _nextCursor() {
    _cursorSequence += 1;
    return _cursorSequence.toString();
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
    _history(collection).add(event);
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
    _history(collection).add(event);
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
    final index = history.indexWhere((event) => event.cursor == afterCursor);
    if (index == -1) {
      throw RpcDataError.invalidArgument(
        'Cursor $afterCursor is not known for $collection',
      );
    }
    return history.sublist(index + 1);
  }

  @override
  Future<void> purgeCollection(String collection) async {
    _events.remove(collection);
  }

  @override
  Future<void> dispose() async {
    _events.clear();
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
