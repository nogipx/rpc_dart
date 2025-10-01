import 'package:meta/meta.dart';
import 'package:rpc_dart/rpc_dart.dart';

import 'models.dart';

/// Контракт сервиса данных с именем DataService.
abstract interface class IDataServiceContract implements IRpcContract {
  /// Имя сервиса в реестре RPC.
  static const String name = 'DataService';

  /// Метод создания записи.
  static const String createRecord = 'createRecord';

  /// Метод получения записи.
  static const String getRecord = 'getRecord';

  /// Метод листинга записей.
  static const String listRecords = 'listRecords';

  /// Полное обновление записи.
  static const String updateRecord = 'updateRecord';

  /// Частичное обновление записи.
  static const String patchRecord = 'patchRecord';

  /// Удаление записи.
  static const String deleteRecord = 'deleteRecord';

  /// Массовый upsert записей.
  static const String bulkUpsert = 'bulkUpsert';

  /// Массовое удаление записей.
  static const String bulkDelete = 'bulkDelete';

  /// Экспорт моментального снимка коллекции.
  static const String exportSnapshot = 'exportSnapshot';

  /// Поиск записей.
  static const String searchRecords = 'searchRecords';

  /// Расчет агрегатов.
  static const String aggregateMetrics = 'aggregateMetrics';

  /// Подписка на поток изменений.
  static const String watchChanges = 'watchChanges';

  /// Двунаправленная синхронизация офлайн клиента.
  static const String syncChanges = 'syncChanges';

  @override
  String get serviceName => IDataServiceContract.name;
}

/// Базовый класс для ошибок сервиса данных.
@immutable
class RpcDataError extends RpcException {
  RpcDataError(
    super.message, {
    required this.status,
    this.code,
    this.details,
  });

  final int status;
  final String? code;
  final Map<String, dynamic>? details;

  factory RpcDataError.permissionDenied(String message) => RpcDataError(
        message,
        status: RpcStatus.permissionDenied,
        code: 'PERMISSION_DENIED',
      );

  factory RpcDataError.cancelled(String message) => RpcDataError(
        message,
        status: RpcStatus.cancelled,
        code: 'CANCELLED',
      );

  factory RpcDataError.invalidArgument(String message,
          {Map<String, dynamic>? details}) =>
      RpcDataError(
        message,
        status: RpcStatus.invalidArgument,
        code: 'INVALID_ARGUMENT',
        details: details,
      );

  factory RpcDataError.notFound(String message) => RpcDataError(
        message,
        status: RpcStatus.notFound,
        code: 'NOT_FOUND',
      );

  factory RpcDataError.conflict(String message,
          {Map<String, dynamic>? details}) =>
      RpcDataError(
        message,
        status: RpcStatus.aborted,
        code: 'VERSION_CONFLICT',
        details: details,
      );

  factory RpcDataError.unauthenticated(String message) => RpcDataError(
        message,
        status: RpcStatus.unauthenticated,
        code: 'UNAUTHENTICATED',
      );

  factory RpcDataError.internal(String message, {Object? error}) =>
      RpcDataError(
        message,
        status: RpcStatus.internal,
        code: 'INTERNAL',
        details: error != null ? {'cause': error.toString()} : null,
      );

  factory RpcDataError.deadlineExceeded(String message) => RpcDataError(
        message,
        status: RpcStatus.deadlineExceeded,
        code: 'DEADLINE_EXCEEDED',
      );
}

const RpcCodec<CreateRecordRequest> createRequestCodec =
    RpcCodec.withDecoder(CreateRecordRequest.fromJson);
const RpcCodec<CreateRecordResponse> createResponseCodec =
    RpcCodec.withDecoder(CreateRecordResponse.fromJson);
const RpcCodec<GetRecordRequest> getRequestCodec =
    RpcCodec.withDecoder(GetRecordRequest.fromJson);
const RpcCodec<GetRecordResponse> getResponseCodec =
    RpcCodec.withDecoder(GetRecordResponse.fromJson);
const RpcCodec<ListRecordsRequest> listRequestCodec =
    RpcCodec.withDecoder(ListRecordsRequest.fromJson);
const RpcCodec<ListRecordsResponse> listResponseCodec =
    RpcCodec.withDecoder(ListRecordsResponse.fromJson);
const RpcCodec<UpdateRecordRequest> updateRequestCodec =
    RpcCodec.withDecoder(UpdateRecordRequest.fromJson);
const RpcCodec<UpdateRecordResponse> updateResponseCodec =
    RpcCodec.withDecoder(UpdateRecordResponse.fromJson);
final RpcCodec<PatchRecordRequest> patchRequestCodec =
    RpcCodec.withDecoder(PatchRecordRequest.fromJson);
const RpcCodec<PatchRecordResponse> patchResponseCodec =
    RpcCodec.withDecoder(PatchRecordResponse.fromJson);
const RpcCodec<DeleteRecordRequest> deleteRequestCodec =
    RpcCodec.withDecoder(DeleteRecordRequest.fromJson);
const RpcCodec<DeleteRecordResponse> deleteResponseCodec =
    RpcCodec.withDecoder(DeleteRecordResponse.fromJson);
const RpcCodec<DataRecord> recordCodec =
    RpcCodec.withDecoder(DataRecord.fromJson);
const RpcCodec<BulkUpsertResponse> bulkUpsertResponseCodec =
    RpcCodec.withDecoder(BulkUpsertResponse.fromJson);
const RpcCodec<BulkDeleteRequest> bulkDeleteRequestCodec =
    RpcCodec.withDecoder(BulkDeleteRequest.fromJson);
const RpcCodec<BulkDeleteResponse> bulkDeleteResponseCodec =
    RpcCodec.withDecoder(BulkDeleteResponse.fromJson);
const RpcCodec<ExportSnapshotRequest> exportRequestCodec =
    RpcCodec.withDecoder(ExportSnapshotRequest.fromJson);
const RpcCodec<ExportSnapshotResponse> exportResponseCodec =
    RpcCodec.withDecoder(ExportSnapshotResponse.fromJson);
const RpcCodec<SearchRecordsRequest> searchRequestCodec =
    RpcCodec.withDecoder(SearchRecordsRequest.fromJson);
const RpcCodec<SearchRecordsResponse> searchResponseCodec =
    RpcCodec.withDecoder(SearchRecordsResponse.fromJson);
const RpcCodec<AggregateMetricsRequest> aggregateRequestCodec =
    RpcCodec.withDecoder(AggregateMetricsRequest.fromJson);
const RpcCodec<AggregateMetricsResponse> aggregateResponseCodec =
    RpcCodec.withDecoder(AggregateMetricsResponse.fromJson);
const RpcCodec<WatchChangesRequest> watchRequestCodec =
    RpcCodec.withDecoder(WatchChangesRequest.fromJson);
const RpcCodec<DataChangeEvent> changeEventCodec =
    RpcCodec.withDecoder(DataChangeEvent.fromJson);
const RpcCodec<SyncChangeRequest> syncRequestCodec =
    RpcCodec.withDecoder(SyncChangeRequest.fromJson);
const RpcCodec<SyncChangeResponse> syncResponseCodec =
    RpcCodec.withDecoder(SyncChangeResponse.fromJson);
