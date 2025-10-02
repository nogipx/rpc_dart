import 'package:collection/collection.dart';
import 'package:equatable/equatable.dart';
import 'package:meta/meta.dart';
import 'package:rpc_dart/rpc_dart.dart';

/// Тип изменения записи в потоке изменений.
enum DataChangeType { created, updated, patched, deleted, snapshot }

/// Тип команды для офлайн-синхронизации и command pattern.
enum DataCommandType { create, update, patch, delete }

String _commandTypeToJson(DataCommandType type) {
  return switch (type) {
    DataCommandType.create => 'create',
    DataCommandType.update => 'update',
    DataCommandType.patch => 'patch',
    DataCommandType.delete => 'delete',
  };
}

DataCommandType _commandTypeFromJson(String value) {
  return switch (value) {
    'create' => DataCommandType.create,
    'update' => DataCommandType.update,
    'patch' => DataCommandType.patch,
    'delete' => DataCommandType.delete,
    _ => throw ArgumentError.value(value, 'value', 'Unknown command type'),
  };
}

/// Команда для отложенного выполнения операций над данными.
///
/// Команда описывает тип действия и полезную нагрузку, которая повторяет
/// формат соответствующих RPC-запросов (`CreateRecordRequest` и т.д.).
/// Клиенты могут складировать команды локально и позже реплицировать их через
/// `syncChanges`, не теряя контекст сессии и времени создания.
@immutable
class DataCommand extends Equatable implements IRpcSerializable {
  const DataCommand({
    required this.commandId,
    required this.sessionId,
    required this.type,
    required this.payload,
    required this.issuedAt,
  });

  factory DataCommand.fromJson(Map<String, dynamic> json) => DataCommand(
        commandId: json['commandId'] as String,
        sessionId: json['sessionId'] as String,
        type: _commandTypeFromJson(json['type'] as String),
        payload: Map<String, dynamic>.from(json['payload'] as Map),
        issuedAt: DateTime.parse(json['issuedAt'] as String),
      );

  /// Уникальный идентификатор команды, генерируемый клиентом.
  final String commandId;

  /// Идентификатор клиентской сессии, к которой относится команда.
  final String sessionId;

  /// Тип действия.
  final DataCommandType type;

  /// Полезная нагрузка, содержащая сериализованный RPC-запрос.
  final Map<String, dynamic> payload;

  /// Время создания команды на клиенте.
  final DateTime issuedAt;

  @override
  List<Object?> get props => [commandId, sessionId, type, payload, issuedAt];

  @override
  Map<String, dynamic> toJson() => {
        'commandId': commandId,
        'sessionId': sessionId,
        'type': _commandTypeToJson(type),
        'payload': payload,
        'issuedAt': issuedAt.toIso8601String(),
      };
}

/// Неизменяемая запись данных.
@immutable
class DataRecord implements IRpcSerializable {
  DataRecord({
    required this.id,
    required this.collection,
    required Map<String, dynamic> payload,
    required this.version,
    required this.createdAt,
    required this.updatedAt,
  }) : payload = Map<String, dynamic>.unmodifiable(payload);

  factory DataRecord.fromJson(Map<String, dynamic> json) {
    return DataRecord(
      id: json['id'] as String,
      collection: json['collection'] as String,
      payload: Map<String, dynamic>.from(json['payload'] as Map),
      version: json['version'] as int,
      createdAt: DateTime.parse(json['createdAt'] as String),
      updatedAt: DateTime.parse(json['updatedAt'] as String),
    );
  }

  final String id;
  final String collection;
  final Map<String, dynamic> payload;
  final int version;
  final DateTime createdAt;
  final DateTime updatedAt;

  static const DeepCollectionEquality _payloadEquality =
      DeepCollectionEquality.unordered();

  DataRecord copyWith({
    Map<String, dynamic>? payload,
    int? version,
    DateTime? updatedAt,
  }) {
    return DataRecord(
      id: id,
      collection: collection,
      payload: payload ?? this.payload,
      version: version ?? this.version,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  @override
  Map<String, dynamic> toJson() => {
        'id': id,
        'collection': collection,
        'payload': payload,
        'version': version,
        'createdAt': createdAt.toIso8601String(),
        'updatedAt': updatedAt.toIso8601String(),
      };

  @override
  bool operator ==(Object other) {
    return other is DataRecord &&
        other.id == id &&
        other.collection == collection &&
        other.version == version &&
        other.createdAt == createdAt &&
        other.updatedAt == updatedAt &&
        _payloadEquality.equals(other.payload, payload);
  }

  @override
  int get hashCode => Object.hash(
        id,
        collection,
        version,
        createdAt,
        updatedAt,
        _payloadEquality.hash(payload),
      );
}

@immutable
class RecordFilter extends Equatable implements IRpcSerializable {
  const RecordFilter({
    this.equals = const {},
    this.range = const {},
    this.containsTerms = const [],
  });

  factory RecordFilter.fromJson(Map<String, dynamic> json) {
    return RecordFilter(
      equals: Map<String, dynamic>.from(json['equals'] as Map? ?? const {}),
      range: (json['range'] as Map? ?? const {}).map((key, value) => MapEntry(
          key as String,
          RangeFilter.fromJson(Map<String, dynamic>.from(value as Map)))),
      containsTerms:
          List<String>.from(json['containsTerms'] as List? ?? const []),
    );
  }

  final Map<String, dynamic> equals;
  final Map<String, RangeFilter> range;
  final List<String> containsTerms;

  @override
  List<Object?> get props => [equals, range, containsTerms];

  @override
  Map<String, dynamic> toJson() => {
        'equals': equals,
        'range': range.map((key, value) => MapEntry(key, value.toJson())),
        'containsTerms': containsTerms,
      };
}

@immutable
class RangeFilter extends Equatable implements IRpcSerializable {
  const RangeFilter(
      {this.min, this.max, this.includeMin = true, this.includeMax = true});

  factory RangeFilter.fromJson(Map<String, dynamic> json) {
    return RangeFilter(
      min: json['min'] as num?,
      max: json['max'] as num?,
      includeMin: json['includeMin'] as bool? ?? true,
      includeMax: json['includeMax'] as bool? ?? true,
    );
  }

  final num? min;
  final num? max;
  final bool includeMin;
  final bool includeMax;

  @override
  List<Object?> get props => [min, max, includeMin, includeMax];

  @override
  Map<String, dynamic> toJson() => {
        'min': min,
        'max': max,
        'includeMin': includeMin,
        'includeMax': includeMax,
      };
}

@immutable
class SortOrder extends Equatable implements IRpcSerializable {
  const SortOrder({required this.field, this.descending = false});

  factory SortOrder.fromJson(Map<String, dynamic> json) => SortOrder(
        field: json['field'] as String,
        descending: json['descending'] as bool? ?? false,
      );

  final String field;
  final bool descending;

  @override
  List<Object?> get props => [field, descending];

  @override
  Map<String, dynamic> toJson() => {
        'field': field,
        'descending': descending,
      };
}

@immutable
class QueryOptions extends Equatable implements IRpcSerializable {
  const QueryOptions({
    this.limit = 20,
    this.cursor,
    this.includeTotalCount = false,
  });

  factory QueryOptions.fromJson(Map<String, dynamic> json) => QueryOptions(
        limit: json['limit'] as int? ?? 20,
        cursor: json['cursor'] as String?,
        includeTotalCount: json['includeTotalCount'] as bool? ?? false,
      );

  final int limit;
  final String? cursor;
  final bool includeTotalCount;

  @override
  List<Object?> get props => [limit, cursor, includeTotalCount];

  @override
  Map<String, dynamic> toJson() => {
        'limit': limit,
        'cursor': cursor,
        'includeTotalCount': includeTotalCount,
      };
}

@immutable
class RecordPatch extends Equatable implements IRpcSerializable {
  const RecordPatch({this.set = const {}, this.unset = const []});

  factory RecordPatch.fromJson(Map<String, dynamic> json) => RecordPatch(
        set: Map<String, dynamic>.from(json['set'] as Map? ?? const {}),
        unset: List<String>.from(json['unset'] as List? ?? const []),
      );

  final Map<String, dynamic> set;
  final List<String> unset;

  Map<String, dynamic> apply(Map<String, dynamic> source) {
    final result = Map<String, dynamic>.from(source)..addAll(set);
    for (final key in unset) {
      result.remove(key);
    }
    return result;
  }

  @override
  List<Object?> get props => [set, unset];

  @override
  Map<String, dynamic> toJson() => {
        'set': set,
        'unset': unset,
      };
}

@immutable
class DataChangeEvent extends Equatable implements IRpcSerializable {
  const DataChangeEvent({
    required this.type,
    required this.collection,
    required this.id,
    this.record,
    required this.version,
    required this.cursor,
    required this.occurredAt,
  });

  factory DataChangeEvent.fromJson(Map<String, dynamic> json) =>
      DataChangeEvent(
        type: DataChangeType.values
            .firstWhere((e) => e.name == (json['type'] as String)),
        collection: json['collection'] as String,
        id: json['id'] as String,
        record: json['record'] == null
            ? null
            : DataRecord.fromJson(
                Map<String, dynamic>.from(json['record'] as Map)),
        version: json['version'] as int,
        cursor: json['cursor'] as String,
        occurredAt: DateTime.parse(json['occurredAt'] as String),
      );

  final DataChangeType type;
  final String collection;
  final String id;
  final DataRecord? record;
  final int version;
  final String cursor;
  final DateTime occurredAt;

  DataChangeEvent copyWith({String? cursor}) => DataChangeEvent(
        type: type,
        collection: collection,
        id: id,
        record: record,
        version: version,
        cursor: cursor ?? this.cursor,
        occurredAt: occurredAt,
      );

  @override
  List<Object?> get props =>
      [type, collection, id, record, version, cursor, occurredAt];

  @override
  Map<String, dynamic> toJson() => {
        'type': type.name,
        'collection': collection,
        'id': id,
        'record': record?.toJson(),
        'version': version,
        'cursor': cursor,
        'occurredAt': occurredAt.toIso8601String(),
      };
}

@immutable
class CreateRecordRequest extends Equatable implements IRpcSerializable {
  const CreateRecordRequest({
    required this.collection,
    required this.payload,
    this.id,
  });

  factory CreateRecordRequest.fromJson(Map<String, dynamic> json) =>
      CreateRecordRequest(
        collection: json['collection'] as String,
        payload: Map<String, dynamic>.from(json['payload'] as Map),
        id: json['id'] as String?,
      );

  final String collection;
  final Map<String, dynamic> payload;
  final String? id;

  @override
  List<Object?> get props => [collection, payload, id];

  @override
  Map<String, dynamic> toJson() => {
        'collection': collection,
        'payload': payload,
        'id': id,
      };
}

@immutable
class CreateRecordResponse extends Equatable implements IRpcSerializable {
  const CreateRecordResponse({required this.record});

  factory CreateRecordResponse.fromJson(Map<String, dynamic> json) =>
      CreateRecordResponse(
        record: DataRecord.fromJson(
            Map<String, dynamic>.from(json['record'] as Map)),
      );

  final DataRecord record;

  @override
  List<Object?> get props => [record];

  @override
  Map<String, dynamic> toJson() => {'record': record.toJson()};
}

@immutable
class GetRecordRequest extends Equatable implements IRpcSerializable {
  const GetRecordRequest({required this.collection, required this.id});

  factory GetRecordRequest.fromJson(Map<String, dynamic> json) =>
      GetRecordRequest(
        collection: json['collection'] as String,
        id: json['id'] as String,
      );

  final String collection;
  final String id;

  @override
  List<Object?> get props => [collection, id];

  @override
  Map<String, dynamic> toJson() => {
        'collection': collection,
        'id': id,
      };
}

@immutable
class GetRecordResponse extends Equatable implements IRpcSerializable {
  const GetRecordResponse({this.record});

  factory GetRecordResponse.fromJson(Map<String, dynamic> json) =>
      GetRecordResponse(
        record: json['record'] == null
            ? null
            : DataRecord.fromJson(
                Map<String, dynamic>.from(json['record'] as Map)),
      );

  final DataRecord? record;

  @override
  List<Object?> get props => [record];

  @override
  Map<String, dynamic> toJson() => {'record': record?.toJson()};
}

@immutable
class ListRecordsRequest extends Equatable implements IRpcSerializable {
  const ListRecordsRequest({
    required this.collection,
    this.filter,
    this.sort,
    this.options = const QueryOptions(),
  });

  factory ListRecordsRequest.fromJson(Map<String, dynamic> json) =>
      ListRecordsRequest(
        collection: json['collection'] as String,
        filter: json['filter'] == null
            ? null
            : RecordFilter.fromJson(
                Map<String, dynamic>.from(json['filter'] as Map)),
        sort: json['sort'] == null
            ? null
            : SortOrder.fromJson(
                Map<String, dynamic>.from(json['sort'] as Map)),
        options: json['options'] == null
            ? const QueryOptions()
            : QueryOptions.fromJson(
                Map<String, dynamic>.from(json['options'] as Map)),
      );

  final String collection;
  final RecordFilter? filter;
  final SortOrder? sort;
  final QueryOptions options;

  @override
  List<Object?> get props => [collection, filter, sort, options];

  @override
  Map<String, dynamic> toJson() => {
        'collection': collection,
        'filter': filter?.toJson(),
        'sort': sort?.toJson(),
        'options': options.toJson(),
      };
}

@immutable
class ListRecordsResponse extends Equatable implements IRpcSerializable {
  const ListRecordsResponse({
    required this.records,
    this.nextCursor,
    this.totalCount,
  });

  factory ListRecordsResponse.fromJson(Map<String, dynamic> json) =>
      ListRecordsResponse(
        records: (json['records'] as List? ?? const [])
            .map(
                (e) => DataRecord.fromJson(Map<String, dynamic>.from(e as Map)))
            .toList(growable: false),
        nextCursor: json['nextCursor'] as String?,
        totalCount: json['totalCount'] as int?,
      );

  final List<DataRecord> records;
  final String? nextCursor;
  final int? totalCount;

  @override
  List<Object?> get props => [records, nextCursor, totalCount];

  @override
  Map<String, dynamic> toJson() => {
        'records': records.map((e) => e.toJson()).toList(growable: false),
        'nextCursor': nextCursor,
        'totalCount': totalCount,
      };
}

@immutable
class UpdateRecordRequest extends Equatable implements IRpcSerializable {
  const UpdateRecordRequest({
    required this.collection,
    required this.id,
    required this.expectedVersion,
    required this.payload,
  });

  factory UpdateRecordRequest.fromJson(Map<String, dynamic> json) =>
      UpdateRecordRequest(
        collection: json['collection'] as String,
        id: json['id'] as String,
        expectedVersion: json['expectedVersion'] as int,
        payload: Map<String, dynamic>.from(json['payload'] as Map),
      );

  final String collection;
  final String id;
  final int expectedVersion;
  final Map<String, dynamic> payload;

  @override
  List<Object?> get props => [collection, id, expectedVersion, payload];

  @override
  Map<String, dynamic> toJson() => {
        'collection': collection,
        'id': id,
        'expectedVersion': expectedVersion,
        'payload': payload,
      };
}

@immutable
class UpdateRecordResponse extends Equatable implements IRpcSerializable {
  const UpdateRecordResponse({required this.record});

  factory UpdateRecordResponse.fromJson(Map<String, dynamic> json) =>
      UpdateRecordResponse(
        record: DataRecord.fromJson(
            Map<String, dynamic>.from(json['record'] as Map)),
      );

  final DataRecord record;

  @override
  List<Object?> get props => [record];

  @override
  Map<String, dynamic> toJson() => {'record': record.toJson()};
}

@immutable
class PatchRecordRequest extends Equatable implements IRpcSerializable {
  const PatchRecordRequest({
    required this.collection,
    required this.id,
    required this.expectedVersion,
    required this.patch,
  });

  factory PatchRecordRequest.fromJson(Map<String, dynamic> json) =>
      PatchRecordRequest(
        collection: json['collection'] as String,
        id: json['id'] as String,
        expectedVersion: json['expectedVersion'] as int,
        patch: RecordPatch.fromJson(
            Map<String, dynamic>.from(json['patch'] as Map)),
      );

  final String collection;
  final String id;
  final int expectedVersion;
  final RecordPatch patch;

  @override
  List<Object?> get props => [collection, id, expectedVersion, patch];

  @override
  Map<String, dynamic> toJson() => {
        'collection': collection,
        'id': id,
        'expectedVersion': expectedVersion,
        'patch': patch.toJson(),
      };
}

@immutable
class PatchRecordResponse extends Equatable implements IRpcSerializable {
  const PatchRecordResponse({required this.record});

  factory PatchRecordResponse.fromJson(Map<String, dynamic> json) =>
      PatchRecordResponse(
        record: DataRecord.fromJson(
            Map<String, dynamic>.from(json['record'] as Map)),
      );

  final DataRecord record;

  @override
  List<Object?> get props => [record];

  @override
  Map<String, dynamic> toJson() => {'record': record.toJson()};
}

@immutable
class DeleteRecordRequest extends Equatable implements IRpcSerializable {
  const DeleteRecordRequest({
    required this.collection,
    required this.id,
    this.expectedVersion,
  });

  factory DeleteRecordRequest.fromJson(Map<String, dynamic> json) =>
      DeleteRecordRequest(
        collection: json['collection'] as String,
        id: json['id'] as String,
        expectedVersion: json['expectedVersion'] as int?,
      );

  final String collection;
  final String id;
  final int? expectedVersion;

  @override
  List<Object?> get props => [collection, id, expectedVersion];

  @override
  Map<String, dynamic> toJson() => {
        'collection': collection,
        'id': id,
        'expectedVersion': expectedVersion,
      };
}

@immutable
class DeleteRecordResponse extends Equatable implements IRpcSerializable {
  const DeleteRecordResponse({required this.deleted});

  factory DeleteRecordResponse.fromJson(Map<String, dynamic> json) =>
      DeleteRecordResponse(deleted: json['deleted'] as bool? ?? false);

  final bool deleted;

  @override
  List<Object?> get props => [deleted];

  @override
  Map<String, dynamic> toJson() => {'deleted': deleted};
}

@immutable
class DeleteCollectionRequest extends Equatable
    implements IRpcSerializable {
  const DeleteCollectionRequest({required this.collection});

  factory DeleteCollectionRequest.fromJson(Map<String, dynamic> json) =>
      DeleteCollectionRequest(collection: json['collection'] as String);

  final String collection;

  @override
  List<Object?> get props => [collection];

  @override
  Map<String, dynamic> toJson() => {'collection': collection};
}

@immutable
class DeleteCollectionResponse extends Equatable
    implements IRpcSerializable {
  const DeleteCollectionResponse({required this.deleted});

  factory DeleteCollectionResponse.fromJson(Map<String, dynamic> json) =>
      DeleteCollectionResponse(deleted: json['deleted'] as bool? ?? false);

  final bool deleted;

  @override
  List<Object?> get props => [deleted];

  @override
  Map<String, dynamic> toJson() => {'deleted': deleted};
}

@immutable
class BulkUpsertRequest extends Equatable implements IRpcSerializable {
  const BulkUpsertRequest({required this.records});

  factory BulkUpsertRequest.fromJson(Map<String, dynamic> json) =>
      BulkUpsertRequest(
        records: (json['records'] as List)
            .map(
                (e) => DataRecord.fromJson(Map<String, dynamic>.from(e as Map)))
            .toList(growable: false),
      );

  final List<DataRecord> records;

  @override
  List<Object?> get props => [records];

  @override
  Map<String, dynamic> toJson() => {
        'records': records.map((e) => e.toJson()).toList(growable: false),
      };
}

@immutable
class BulkUpsertResponse extends Equatable implements IRpcSerializable {
  const BulkUpsertResponse({required this.records});

  factory BulkUpsertResponse.fromJson(Map<String, dynamic> json) =>
      BulkUpsertResponse(
        records: (json['records'] as List)
            .map(
                (e) => DataRecord.fromJson(Map<String, dynamic>.from(e as Map)))
            .toList(growable: false),
      );

  final List<DataRecord> records;

  @override
  List<Object?> get props => [records];

  @override
  Map<String, dynamic> toJson() => {
        'records': records.map((e) => e.toJson()).toList(growable: false),
      };
}

@immutable
class BulkDeleteRequest extends Equatable implements IRpcSerializable {
  const BulkDeleteRequest({required this.collection, required this.ids});

  factory BulkDeleteRequest.fromJson(Map<String, dynamic> json) =>
      BulkDeleteRequest(
        collection: json['collection'] as String,
        ids: List<String>.from(json['ids'] as List),
      );

  final String collection;
  final List<String> ids;

  @override
  List<Object?> get props => [collection, ids];

  @override
  Map<String, dynamic> toJson() => {
        'collection': collection,
        'ids': ids,
      };
}

@immutable
class BulkDeleteResponse extends Equatable implements IRpcSerializable {
  const BulkDeleteResponse({required this.deletedCount});

  factory BulkDeleteResponse.fromJson(Map<String, dynamic> json) =>
      BulkDeleteResponse(deletedCount: json['deletedCount'] as int);

  final int deletedCount;

  @override
  List<Object?> get props => [deletedCount];

  @override
  Map<String, dynamic> toJson() => {'deletedCount': deletedCount};
}

@immutable
class ExportSnapshotRequest extends Equatable implements IRpcSerializable {
  const ExportSnapshotRequest({required this.collection});

  factory ExportSnapshotRequest.fromJson(Map<String, dynamic> json) =>
      ExportSnapshotRequest(collection: json['collection'] as String);

  final String collection;

  @override
  List<Object?> get props => [collection];

  @override
  Map<String, dynamic> toJson() => {'collection': collection};
}

@immutable
class ExportSnapshotResponse extends Equatable implements IRpcSerializable {
  const ExportSnapshotResponse(
      {required this.records, required this.generatedAt});

  factory ExportSnapshotResponse.fromJson(Map<String, dynamic> json) =>
      ExportSnapshotResponse(
        records: (json['records'] as List)
            .map(
                (e) => DataRecord.fromJson(Map<String, dynamic>.from(e as Map)))
            .toList(growable: false),
        generatedAt: DateTime.parse(json['generatedAt'] as String),
      );

  final List<DataRecord> records;
  final DateTime generatedAt;

  @override
  List<Object?> get props => [records, generatedAt];

  @override
  Map<String, dynamic> toJson() => {
        'records': records.map((e) => e.toJson()).toList(growable: false),
        'generatedAt': generatedAt.toIso8601String(),
      };
}

@immutable
class SearchRecordsRequest extends Equatable implements IRpcSerializable {
  const SearchRecordsRequest({
    required this.collection,
    required this.query,
    this.filter,
    this.options = const QueryOptions(),
  });

  factory SearchRecordsRequest.fromJson(Map<String, dynamic> json) =>
      SearchRecordsRequest(
        collection: json['collection'] as String,
        query: json['query'] as String,
        filter: json['filter'] == null
            ? null
            : RecordFilter.fromJson(
                Map<String, dynamic>.from(json['filter'] as Map)),
        options: json['options'] == null
            ? const QueryOptions()
            : QueryOptions.fromJson(
                Map<String, dynamic>.from(json['options'] as Map)),
      );

  final String collection;
  final String query;
  final RecordFilter? filter;
  final QueryOptions options;

  @override
  List<Object?> get props => [collection, query, filter, options];

  @override
  Map<String, dynamic> toJson() => {
        'collection': collection,
        'query': query,
        'filter': filter?.toJson(),
        'options': options.toJson(),
      };
}

@immutable
class SearchRecordsResponse extends Equatable implements IRpcSerializable {
  const SearchRecordsResponse({
    required this.records,
    required this.totalHits,
    this.nextCursor,
  });

  factory SearchRecordsResponse.fromJson(Map<String, dynamic> json) =>
      SearchRecordsResponse(
        records: (json['records'] as List)
            .map(
                (e) => DataRecord.fromJson(Map<String, dynamic>.from(e as Map)))
            .toList(growable: false),
        totalHits: json['totalHits'] as int,
        nextCursor: json['nextCursor'] as String?,
      );

  final List<DataRecord> records;
  final int totalHits;
  final String? nextCursor;

  @override
  List<Object?> get props => [records, totalHits, nextCursor];

  @override
  Map<String, dynamic> toJson() => {
        'records': records.map((e) => e.toJson()).toList(growable: false),
        'totalHits': totalHits,
        'nextCursor': nextCursor,
      };
}

@immutable
class AggregateMetricsRequest extends Equatable implements IRpcSerializable {
  const AggregateMetricsRequest({
    required this.collection,
    this.filter,
    this.metrics = const {},
  });

  factory AggregateMetricsRequest.fromJson(Map<String, dynamic> json) =>
      AggregateMetricsRequest(
        collection: json['collection'] as String,
        filter: json['filter'] == null
            ? null
            : RecordFilter.fromJson(
                Map<String, dynamic>.from(json['filter'] as Map)),
        metrics: Map<String, String>.from(json['metrics'] as Map? ?? const {}),
      );

  final String collection;
  final RecordFilter? filter;
  final Map<String, String> metrics;

  @override
  List<Object?> get props => [collection, filter, metrics];

  @override
  Map<String, dynamic> toJson() => {
        'collection': collection,
        'filter': filter?.toJson(),
        'metrics': metrics,
      };
}

@immutable
class AggregateMetricsResponse extends Equatable implements IRpcSerializable {
  const AggregateMetricsResponse({required this.metrics});

  factory AggregateMetricsResponse.fromJson(Map<String, dynamic> json) =>
      AggregateMetricsResponse(
        metrics: Map<String, num>.from(json['metrics'] as Map),
      );

  final Map<String, num> metrics;

  @override
  List<Object?> get props => [metrics];

  @override
  Map<String, dynamic> toJson() => {'metrics': metrics};
}

@immutable
class WatchChangesRequest extends Equatable implements IRpcSerializable {
  const WatchChangesRequest({required this.collection, this.cursor});

  factory WatchChangesRequest.fromJson(Map<String, dynamic> json) =>
      WatchChangesRequest(
        collection: json['collection'] as String,
        cursor: json['cursor'] as String?,
      );

  final String collection;
  final String? cursor;

  @override
  List<Object?> get props => [collection, cursor];

  @override
  Map<String, dynamic> toJson() => {
        'collection': collection,
        'cursor': cursor,
      };
}

@immutable
class SyncChangeRequest extends Equatable implements IRpcSerializable {
  const SyncChangeRequest({
    required this.requestId,
    required this.command,
    this.resolveConflicts = true,
  });

  factory SyncChangeRequest.fromJson(Map<String, dynamic> json) =>
      SyncChangeRequest(
        requestId: json['requestId'] as String,
        command: DataCommand.fromJson(
            Map<String, dynamic>.from(json['command'] as Map)),
        resolveConflicts: json['resolveConflicts'] as bool? ?? true,
      );

  final String requestId;
  final DataCommand command;
  final bool resolveConflicts;

  @override
  List<Object?> get props => [requestId, command, resolveConflicts];

  @override
  Map<String, dynamic> toJson() => {
        'requestId': requestId,
        'command': command.toJson(),
        'resolveConflicts': resolveConflicts,
      };
}

@immutable
class SyncChangeResponse extends Equatable implements IRpcSerializable {
  const SyncChangeResponse({
    required this.requestId,
    required this.commandId,
    required this.applied,
    this.record,
    this.conflict,
    this.error,
  });

  factory SyncChangeResponse.fromJson(Map<String, dynamic> json) =>
      SyncChangeResponse(
        requestId: json['requestId'] as String,
        commandId: json['commandId'] as String,
        applied: json['applied'] as bool,
        record: json['record'] == null
            ? null
            : DataRecord.fromJson(
                Map<String, dynamic>.from(json['record'] as Map)),
        conflict: json['conflict'] == null
            ? null
            : DataRecord.fromJson(
                Map<String, dynamic>.from(json['conflict'] as Map)),
        error: json['error'] as String?,
      );

  final String requestId;
  final String commandId;
  final bool applied;
  final DataRecord? record;
  final DataRecord? conflict;
  final String? error;

  bool get hasConflict => conflict != null;

  @override
  List<Object?> get props =>
      [requestId, commandId, applied, record, conflict, error];

  @override
  Map<String, dynamic> toJson() => {
        'requestId': requestId,
        'commandId': commandId,
        'applied': applied,
        'record': record?.toJson(),
        'conflict': conflict?.toJson(),
        'error': error,
      };
}
