import 'package:meta/meta.dart';
import 'package:rpc_dart/rpc_dart.dart';

/// Контракт сервиса данных с именем DataService.
abstract interface class IDataServiceContract implements IRpcContract {
  /// Имя сервиса в реестре RPC.
  static const String serviceName = 'DataService';

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
  String get serviceName => IDataServiceContract.serviceName;
}

/// Базовый класс для ошибок сервиса данных.
@immutable
class RpcError extends RpcException {
  RpcError({
    required super.message,
    required this.status,
    this.code,
    this.details,
  });

  final int status;
  final String? code;
  final Map<String, dynamic>? details;

  factory RpcError.permissionDenied(String message) => RpcError(
        message: message,
        status: RpcStatus.permissionDenied,
        code: 'PERMISSION_DENIED',
      );

  factory RpcError.cancelled(String message) => RpcError(
        message: message,
        status: RpcStatus.cancelled,
        code: 'CANCELLED',
      );

  factory RpcError.invalidArgument(String message,
          {Map<String, dynamic>? details}) =>
      RpcError(
        message: message,
        status: RpcStatus.invalidArgument,
        code: 'INVALID_ARGUMENT',
        details: details,
      );

  factory RpcError.notFound(String message) => RpcError(
        message: message,
        status: RpcStatus.notFound,
        code: 'NOT_FOUND',
      );

  factory RpcError.conflict(String message,
          {Map<String, dynamic>? details}) =>
      RpcError(
        message: message,
        status: RpcStatus.aborted,
        code: 'VERSION_CONFLICT',
        details: details,
      );

  factory RpcError.unauthenticated(String message) => RpcError(
        message: message,
        status: RpcStatus.unauthenticated,
        code: 'UNAUTHENTICATED',
      );

  factory RpcError.internal(String message, {Object? error}) => RpcError(
        message: message,
        status: RpcStatus.internal,
        code: 'INTERNAL',
        details: error != null ? {'cause': error.toString()} : null,
      );

  factory RpcError.deadlineExceeded(String message) => RpcError(
        message: message,
        status: RpcStatus.deadlineExceeded,
        code: 'DEADLINE_EXCEEDED',
      );
}
