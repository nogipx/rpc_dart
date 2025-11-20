import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_data/rpc_dart_data.dart';

/// Высокоуровневый фасад, инкапсулирующий работу с RPC-слоем для сервиса данных.
///
/// Цели:
/// * Спрятать детали RpcCallerEndpoint / RpcResponderEndpoint от прикладного кода;
/// * Дать единый интерфейс для развёртывания сервиса (server side) и вызова (client side);
/// * Упростить создание in-memory окружения (тесты, демо, локальный dev);
/// * Сконцентрировать продвинутые настройки (dataTransferMode, repository и т.п.) в одном месте.
///
/// При необходимости можно обратиться к низкоуровневым классам напрямую (DataServiceCaller
/// и DataServiceResponder) — они продолжают работать как прежде.

/// Унифицированный интерфейс CRUD/Query операций.
/// Возвращает уже "распакованные" данные вместо *Response объектов где это логично.
abstract interface class IDataService {
  Future<DataRecord> create({
    required String collection,
    required Map<String, dynamic> payload,
    String? id,
    RpcContext? context,
  });

  Future<DataRecord?> get({
    required String collection,
    required String id,
    RpcContext? context,
  });

  Future<ListRecordsResponse> list({
    required String collection,
    RecordFilter? filter,
    SortOrder? sort,
    QueryOptions options,
    RpcContext? context,
  });

  /// Выгружает всю коллекцию, последовательно проходя страницы `list`.
  Future<List<DataRecord>> listAllRecords({
    required String collection,
    RecordFilter? filter,
    SortOrder? sort,
    RpcContext? context,
  });

  Future<DataRecord> update({
    required String collection,
    required String id,
    required int expectedVersion,
    required Map<String, dynamic> payload,
    RpcContext? context,
  });

  Future<DataRecord> patch({
    required String collection,
    required String id,
    required int expectedVersion,
    required RecordPatch patch,
    RpcContext? context,
  });

  Future<bool> delete({
    required String collection,
    required String id,
    int? expectedVersion,
    RpcContext? context,
  });

  Future<bool> deleteCollection({
    required String collection,
    RpcContext? context,
  });

  Future<List<DataRecord>> bulkUpsert({
    required Iterable<DataRecord> records,
    RpcContext? context,
  });

  /// Потоковая версия массового upsert-а.
  Future<List<DataRecord>> bulkUpsertStream({
    required Stream<DataRecord> records,
    RpcContext? context,
  });

  Future<int> bulkDelete({
    required String collection,
    required List<String> ids,
    RpcContext? context,
  });

  Future<ExportSnapshotResponse> exportSnapshot({
    required String collection,
    RpcContext? context,
  });

  Future<ExportDatabaseResponse> exportDatabase({RpcContext? context});

  Future<ImportDatabaseResponse> importDatabase({
    required String payload,
    bool replaceExisting = true,
    RpcContext? context,
  });

  Future<SearchRecordsResponse> search({
    required String collection,
    required String query,
    RecordFilter? filter,
    QueryOptions options,
    RpcContext? context,
  });

  Future<AggregateMetricsResponse> aggregate({
    required String collection,
    RecordFilter? filter,
    Map<String, String> metrics,
    RpcContext? context,
  });

  Future<CollectionIndex> createCollectionIndex({
    required String collection,
    required String path,
    String? indexName,
    RpcContext? context,
  });

  Future<bool> deleteCollectionIndex({
    required String collection,
    required String path,
    String? indexName,
    RpcContext? context,
  });

  Stream<DataChangeEvent> watchChanges({
    required String collection,
    String? cursor,
    RpcContext? context,
  });

  /// Двунаправленная синхронизация офлайн-команд.
  Stream<SyncChangeResponse> syncChanges(
    Stream<SyncChangeRequest> requests, {
    RpcContext? context,
  });

  /// Отправляет одиночную команду и дожидается подтверждения.
  Future<SyncChangeResponse> pushAndAwaitAck({
    required SyncChangeRequest request,
    RpcContext? context,
  });

  /// Создает офлайн-очередь команд, привязанную к клиенту.
  OfflineCommandQueue createOfflineQueue({
    String? sessionId,
    DateTime Function()? clock,
    void Function(Object error, StackTrace stackTrace)? onError,
  });

  /// Закрывает RPC-подключение клиента.
  Future<void> close();
}
