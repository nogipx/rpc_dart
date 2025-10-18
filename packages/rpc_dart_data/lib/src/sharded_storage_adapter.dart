import 'dart:async';

import 'data_repository.dart';
import 'models.dart';

/// Signature for determining which shard should handle a storage request.
///
/// The resolver receives the [collection] name alongside optional metadata
/// about the requested record. Returning `null` indicates that the gateway
/// cannot pick a specific shard and should fan the request out to every
/// registered shard (for read-only operations).
typedef ShardResolver = String? Function(
  String collection, {
  String? id,
  DataRecord? record,
});

/// A gateway [DataStorageAdapter] implementation that routes calls to
/// multiple underlying adapters based on a [ShardResolver].
///
/// The gateway keeps the existing repository API intact: from the caller's
/// point of view there is still a single [DataStorageAdapter] instance. The
/// resolver decides which shard is responsible for a particular collection or
/// record. When the resolver returns `null`, the gateway will fan-out the
/// operation to all shards (for read-only methods) or throw if a write action
/// cannot be resolved.
class ShardedDataStorageAdapter implements DataStorageAdapter, CollectionIndexStorageAdapter {
  ShardedDataStorageAdapter({
    required Map<String, DataStorageAdapter> shards,
    required ShardResolver resolver,
  })  : _shards = Map.unmodifiable(shards),
        _resolver = resolver {
    if (_shards.isEmpty) {
      throw ArgumentError.value(shards, 'shards', 'At least one shard is required');
    }
  }

  final Map<String, DataStorageAdapter> _shards;
  final ShardResolver _resolver;

  Iterable<DataStorageAdapter> get _allShards => _shards.values;

  DataStorageAdapter _requireShard(String shardId) {
    final shard = _shards[shardId];
    if (shard == null) {
      throw StateError('Shard "$shardId" is not registered');
    }
    return shard;
  }

  DataStorageAdapter _selectShard(
    String collection, {
    String? id,
    DataRecord? record,
  }) {
    final shardId = _resolver(collection, id: id, record: record);
    if (shardId == null) {
      throw StateError(
        'Shard resolver returned null for collection "$collection"'
        '${id != null ? ', id "$id"' : ''}.',
      );
    }
    return _requireShard(shardId);
  }

  Future<T?> _fanOutFirst<T>(Future<T?> Function(DataStorageAdapter shard) action) async {
    for (final shard in _allShards) {
      final result = await action(shard);
      if (result != null) {
        return result;
      }
    }
    return null;
  }

  Future<bool> _fanOutBool(Future<bool> Function(DataStorageAdapter shard) action) async {
    var success = false;
    for (final shard in _allShards) {
      success = await action(shard) || success;
    }
    return success;
  }

  Future<int> _fanOutInt(Future<int> Function(DataStorageAdapter shard) action) async {
    var total = 0;
    for (final shard in _allShards) {
      total += await action(shard);
    }
    return total;
  }

  Future<List<T>> _fanOutList<T>(Future<List<T>> Function(DataStorageAdapter shard) action) async {
    final results = await Future.wait(_allShards.map(action));
    return results.expand((value) => value).toList();
  }

  @override
  Future<DataRecord?> readRecord(String collection, String id) async {
    final shardId = _resolver(collection, id: id);
    if (shardId != null) {
      return _requireShard(shardId).readRecord(collection, id);
    }
    return _fanOutFirst((shard) => shard.readRecord(collection, id));
  }

  @override
  Future<List<DataRecord>> readCollection(String collection) {
    final shardId = _resolver(collection);
    if (shardId != null) {
      return _requireShard(shardId).readCollection(collection);
    }
    return _fanOutList((shard) => shard.readCollection(collection));
  }

  @override
  Future<List<String>> listCollections() async {
    final results = await Future.wait(
      _allShards.map((shard) => shard.listCollections()),
    );
    return {
      for (final collections in results) ...collections,
    }.toList();
  }

  @override
  Future<void> writeRecord(DataRecord record) {
    final shard = _selectShard(
      record.collection,
      id: record.id,
      record: record,
    );
    return shard.writeRecord(record);
  }

  @override
  Future<void> writeRecords(Iterable<DataRecord> records) {
    final operations = <DataStorageAdapter, List<DataRecord>>{};
    for (final record in records) {
      final shard = _selectShard(
        record.collection,
        id: record.id,
        record: record,
      );
      operations.putIfAbsent(shard, () => <DataRecord>[]).add(record);
    }
    return Future.wait([
      for (final entry in operations.entries)
        entry.key.writeRecords(entry.value),
    ]);
  }

  @override
  Future<bool> deleteRecord(String collection, String id) async {
    final shardId = _resolver(collection, id: id);
    if (shardId != null) {
      return _requireShard(shardId).deleteRecord(collection, id);
    }
    return _fanOutBool((shard) => shard.deleteRecord(collection, id));
  }

  @override
  Future<int> deleteRecords(String collection, Iterable<String> ids) async {
    final grouped = <DataStorageAdapter, List<String>>{};
    for (final id in ids) {
      final shardId = _resolver(collection, id: id);
      if (shardId != null) {
        final shard = _requireShard(shardId);
        grouped.putIfAbsent(shard, () => <String>[]).add(id);
      } else {
        // Fan the deletion out to every shard when the resolver cannot choose.
        return _fanOutInt((shard) => shard.deleteRecords(collection, ids));
      }
    }

    return _fanOutInt((shard) async {
      final shardIds = grouped[shard];
      if (shardIds == null || shardIds.isEmpty) {
        return 0;
      }
      return shard.deleteRecords(collection, shardIds);
    });
  }

  @override
  Future<bool> deleteCollection(String collection) async {
    final shardId = _resolver(collection);
    if (shardId != null) {
      return _requireShard(shardId).deleteCollection(collection);
    }
    return _fanOutBool((shard) => shard.deleteCollection(collection));
  }

  @override
  Future<void> dispose() {
    return Future.wait(_allShards.map((shard) => shard.dispose()));
  }

  @override
  Future<CollectionIndex> createCollectionIndex(
    CreateCollectionIndexRequest request,
  ) async {
    final responses = await Future.wait(
      _allShards
          .whereType<CollectionIndexStorageAdapter>()
          .map((shard) => shard.createCollectionIndex(request)),
    );
    if (responses.isEmpty) {
      throw StateError('None of the shards support collection indexes');
    }
    return responses.first;
  }

  @override
  Future<bool> deleteCollectionIndex(DeleteCollectionIndexRequest request) async {
    final shards = _allShards.whereType<CollectionIndexStorageAdapter>().toList();
    if (shards.isEmpty) {
      throw StateError('None of the shards support collection indexes');
    }
    var success = false;
    for (final shard in shards) {
      success = await shard.deleteCollectionIndex(request) || success;
    }
    return success;
  }
}
