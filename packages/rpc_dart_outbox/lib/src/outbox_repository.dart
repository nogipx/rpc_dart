import 'package:rpc_dart_data/rpc_dart_data.dart';

import 'outbox_entry.dart';
import 'outbox_status.dart';

class OutboxRepository {
  OutboxRepository({
    required this.repository,
    DateTime Function()? clock,
    this.collectionName = 'outbox',
    this.defaultLockDuration = const Duration(minutes: 5),
  }) : _clock = clock ?? (() => DateTime.now().toUtc());

  final IDataRepository repository;
  final DateTime Function() _clock;
  final String collectionName;
  final Duration defaultLockDuration;

  Future<OutboxEntry?> get(String id) async {
    final response = await repository.get(
      GetRecordRequest(collection: collectionName, id: id),
    );
    final record = response;
    if (record == null) return null;
    return OutboxEntry.fromRecord(record);
  }

  Future<OutboxEntry> enqueue({
    required Map<String, dynamic> payload,
    required String topic,
    String? dedupKey,
    DateTime? availableAt,
  }) async {
    if (dedupKey != null) {
      final existing = await _findByDedupKey(dedupKey);
      if (existing != null) {
        return existing;
      }
    }

    final entryPayload = OutboxEntry(
      id: '',
      topic: topic,
      payload: payload,
      status: OutboxStatus.pending,
      attempts: 0,
      availableAt: availableAt ?? _clock(),
      dedupKey: dedupKey,
      lastError: null,
      version: 0,
      createdAt: DateTime.fromMillisecondsSinceEpoch(0),
      updatedAt: DateTime.fromMillisecondsSinceEpoch(0),
    ).toStoragePayload();

    final created = await repository.create(
      CreateRecordRequest(
        collection: collectionName,
        payload: entryPayload,
      ),
    );

    return OutboxEntry.fromRecord(created);
  }

  Future<List<OutboxEntry>> claim({
    int limit = 10,
    Duration? lockDuration,
    String? topic,
    List<String>? topics,
  }) async {
    final now = _clock();
    final lock = lockDuration ?? defaultLockDuration;
    final claimed = <OutboxEntry>[];

    final topicList = topics ?? (topic != null ? [topic] : null);
    if (topicList == null || topicList.isEmpty) {
      claimed.addAll(await _claimBatch(now: now, limit: limit, lock: lock));
      return claimed;
    }

    for (final item in topicList) {
      if (claimed.length >= limit) break;
      final remaining = limit - claimed.length;
      final batch = await _claimBatch(
        now: now,
        limit: remaining,
        lock: lock,
        topic: item,
      );
      claimed.addAll(batch);
    }

    return claimed;
  }

  Future<OutboxEntry?> acknowledge(String id, {int? expectedVersion}) async {
    final record = await _loadRecord(id);
    if (record == null) return null;

    final patched = await _patchEntry(
      record,
      set: {
        'status': OutboxStatus.delivered.name,
        'availableAtEpoch': _clock().microsecondsSinceEpoch,
      },
      unset: const ['lastError'],
      expectedVersion: expectedVersion,
    );

    return patched;
  }

  Future<OutboxEntry?> markFailed(
    String id, {
    String? error,
    int? expectedVersion,
  }) async {
    final record = await _loadRecord(id);
    if (record == null) return null;

    final patched = await _patchEntry(
      record,
      set: {
        'status': OutboxStatus.failed.name,
        'availableAtEpoch': _clock().microsecondsSinceEpoch,
        if (error != null) 'lastError': error,
      },
      unset: error == null ? const ['lastError'] : const [],
      expectedVersion: expectedVersion,
    );

    return patched;
  }

  Future<OutboxEntry?> retryLater(
    String id, {
    Duration delay = const Duration(seconds: 30),
    String? error,
    int? expectedVersion,
  }) async {
    final record = await _loadRecord(id);
    if (record == null) return null;

    final patched = await _patchEntry(
      record,
      set: {
        'status': OutboxStatus.pending.name,
        'availableAtEpoch': _clock().add(delay).microsecondsSinceEpoch,
        if (error != null) 'lastError': error,
      },
      unset: error == null ? const ['lastError'] : const [],
      expectedVersion: expectedVersion,
    );

    return patched;
  }

  Future<List<OutboxEntry>> _claimBatch({
    required DateTime now,
    required int limit,
    required Duration lock,
    String? topic,
  }) async {
    final equalsFilter = {
      'status': OutboxStatus.pending.name,
      if (topic != null) 'topic': topic,
    };

    final response = await repository.list(
      ListRecordsRequest(
        collection: collectionName,
        filter: RecordFilter(
          equals: equalsFilter,
          range: {
            'availableAtEpoch': RangeFilter(max: now.microsecondsSinceEpoch),
          },
        ),
        sort: const SortOrder(field: 'availableAtEpoch'),
        options: QueryOptions(limit: limit),
      ),
    );

    final claimed = <OutboxEntry>[];
    for (final record in response.records) {
      final entry = OutboxEntry.fromRecord(record);
      final patched = await _patchEntry(
        record,
        set: {
          'status': OutboxStatus.processing.name,
          'availableAtEpoch': now.add(lock).microsecondsSinceEpoch,
          'attempts': entry.attempts + 1,
        },
        unset: const ['lastError'],
      );
      claimed.add(patched);
    }
    return claimed;
  }

  Future<DataRecord?> _loadRecord(String id) async {
    final record = await repository.get(
      GetRecordRequest(collection: collectionName, id: id),
    );
    return record;
  }

  Future<OutboxEntry?> _findByDedupKey(String dedupKey) async {
    final response = await repository.list(
      ListRecordsRequest(
        collection: collectionName,
        filter: RecordFilter(
          equals: {'dedupKey': dedupKey},
        ),
        options: const QueryOptions(limit: 1),
      ),
    );
    if (response.records.isEmpty) return null;
    return OutboxEntry.fromRecord(response.records.first);
  }

  Future<OutboxEntry> _patchEntry(
    DataRecord record, {
    required Map<String, dynamic> set,
    required List<String> unset,
    int? expectedVersion,
  }) async {
    final updated = await repository.patch(
      PatchRecordRequest(
        collection: collectionName,
        id: record.id,
        expectedVersion: expectedVersion ?? record.version,
        patch: RecordPatch(set: set, unset: unset),
      ),
    );
    return OutboxEntry.fromRecord(updated);
  }
}
