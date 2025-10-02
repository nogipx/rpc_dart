import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_transports/rpc_dart_transports.dart';

import 'data_caller.dart';
import 'data_repository.dart';
import 'data_responder.dart';
import 'models.dart';

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
abstract interface class DataService {
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

  Future<List<DataRecord>> bulkUpsert({
    required Iterable<DataRecord> records,
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

  Stream<DataChangeEvent> watchChanges({
    required String collection,
    String? cursor,
    RpcContext? context,
  });

  /// Двунаправленная синхронизация офлайн-команд.
  Stream<SyncChangeResponse> syncChanges(Stream<SyncChangeRequest> requests,
      {RpcContext? context});
}

/// Клиентская инкапсуляция. Хранит endpoint и caller и реализует интерфейс DataService.
class DataServiceClient implements DataService {
  DataServiceClient(this._endpoint, this._caller);

  final RpcCallerEndpoint _endpoint;
  final DataServiceCaller _caller;

  RpcCallerEndpoint get endpoint => _endpoint;
  DataServiceCaller get rawCaller => _caller;

  @override
  Future<DataRecord> create({
    required String collection,
    required Map<String, dynamic> payload,
    String? id,
    RpcContext? context,
  }) async {
    final response = await _caller.createRecord(
      CreateRecordRequest(collection: collection, payload: payload, id: id),
      context: context,
    );
    return response.record;
  }

  @override
  Future<DataRecord?> get({
    required String collection,
    required String id,
    RpcContext? context,
  }) async {
    final response = await _caller.getRecord(
      GetRecordRequest(collection: collection, id: id),
      context: context,
    );
    return response.record;
  }

  @override
  Future<ListRecordsResponse> list({
    required String collection,
    RecordFilter? filter,
    SortOrder? sort,
    QueryOptions options = const QueryOptions(),
    RpcContext? context,
  }) {
    return _caller.listRecords(
      ListRecordsRequest(
        collection: collection,
        filter: filter,
        sort: sort,
        options: options,
      ),
      context: context,
    );
  }

  @override
  Future<DataRecord> update({
    required String collection,
    required String id,
    required int expectedVersion,
    required Map<String, dynamic> payload,
    RpcContext? context,
  }) async {
    final response = await _caller.updateRecord(
      UpdateRecordRequest(
        collection: collection,
        id: id,
        expectedVersion: expectedVersion,
        payload: payload,
      ),
      context: context,
    );
    return response.record;
  }

  @override
  Future<DataRecord> patch({
    required String collection,
    required String id,
    required int expectedVersion,
    required RecordPatch patch,
    RpcContext? context,
  }) async {
    final response = await _caller.patchRecord(
      PatchRecordRequest(
        collection: collection,
        id: id,
        expectedVersion: expectedVersion,
        patch: patch,
      ),
      context: context,
    );
    return response.record;
  }

  @override
  Future<bool> delete({
    required String collection,
    required String id,
    int? expectedVersion,
    RpcContext? context,
  }) async {
    final response = await _caller.deleteRecord(
      DeleteRecordRequest(
        collection: collection,
        id: id,
        expectedVersion: expectedVersion,
      ),
      context: context,
    );
    return response.deleted;
  }

  @override
  Future<List<DataRecord>> bulkUpsert({
    required Iterable<DataRecord> records,
    RpcContext? context,
  }) async {
    final response = await _caller
        .bulkUpsert(Stream<DataRecord>.fromIterable(records), context: context);
    return response.records;
  }

  @override
  Future<int> bulkDelete({
    required String collection,
    required List<String> ids,
    RpcContext? context,
  }) async {
    final response = await _caller.bulkDelete(
      BulkDeleteRequest(collection: collection, ids: ids),
      context: context,
    );
    return response.deletedCount;
  }

  @override
  Future<ExportSnapshotResponse> exportSnapshot({
    required String collection,
    RpcContext? context,
  }) {
    return _caller.exportSnapshot(
      ExportSnapshotRequest(collection: collection),
      context: context,
    );
  }

  @override
  Future<SearchRecordsResponse> search({
    required String collection,
    required String query,
    RecordFilter? filter,
    QueryOptions options = const QueryOptions(),
    RpcContext? context,
  }) {
    return _caller.searchRecords(
      SearchRecordsRequest(
        collection: collection,
        query: query,
        filter: filter,
        options: options,
      ),
      context: context,
    );
  }

  @override
  Future<AggregateMetricsResponse> aggregate({
    required String collection,
    RecordFilter? filter,
    Map<String, String> metrics = const {},
    RpcContext? context,
  }) {
    return _caller.aggregateMetrics(
      AggregateMetricsRequest(
        collection: collection,
        filter: filter,
        metrics: metrics,
      ),
      context: context,
    );
  }

  @override
  Stream<DataChangeEvent> watchChanges({
    required String collection,
    String? cursor,
    RpcContext? context,
  }) {
    return _caller.watchChanges(
      WatchChangesRequest(collection: collection, cursor: cursor),
      context: context,
    );
  }

  @override
  Stream<SyncChangeResponse> syncChanges(Stream<SyncChangeRequest> requests,
      {RpcContext? context}) {
    return _caller.syncChanges(requests, context: context);
  }

  Future<void> close() => _endpoint.close();
}

/// Серверная обёртка: содержит endpoint, responder и репозиторий.
class DataServiceServer {
  DataServiceServer({
    required RpcResponderEndpoint endpoint,
    required DataServiceResponder responder,
    required DataRepository repository,
  })  : _endpoint = endpoint,
        _responder = responder,
        _repository = repository;

  final RpcResponderEndpoint _endpoint;
  final DataServiceResponder _responder;
  final DataRepository _repository;

  RpcResponderEndpoint get endpoint => _endpoint;
  DataServiceResponder get rawResponder => _responder;
  DataRepository get repository => _repository;

  Future<void> start() async {
    _endpoint.registerServiceContract(_responder);
    _endpoint.start();
  }

  Future<void> close() async {
    await _endpoint.close();
    await _responder.dispose();
  }
}

/// Результат helper-а для быстрого развёртывания in-memory окружения.
class InMemoryDataServiceEnvironment {
  InMemoryDataServiceEnvironment({
    required this.client,
    required this.server,
    required this.clientTransport,
    required this.serverTransport,
  });

  final DataServiceClient client;
  final DataServiceServer server;
  final IRpcTransport clientTransport;
  final IRpcTransport serverTransport;

  Future<void> dispose() async {
    await client.close();
    await server.close();
  }
}

/// Утилиты для создания сервиса/клиента.
class DataServiceFactory {
  const DataServiceFactory._();

  /// Создать серверную часть поверх произвольного транспорта и репозитория.
  static DataServiceServer createServer({
    required IRpcTransport transport,
    required DataRepository repository,
    String debugLabel = 'DataServiceServer',
  }) {
    final endpoint = RpcResponderEndpoint(
      transport: transport,
      debugLabel: debugLabel,
    );
    final responder = DataServiceResponder(repository: repository);
    return DataServiceServer(
      endpoint: endpoint,
      responder: responder,
      repository: repository,
    );
  }

  /// Создать клиентскую часть.
  static DataServiceClient createClient({
    required IRpcTransport transport,
    String debugLabel = 'DataServiceClient',
  }) {
    final endpoint = RpcCallerEndpoint(
      transport: transport,
      debugLabel: debugLabel,
    );
    final caller = DataServiceCaller(endpoint);
    return DataServiceClient(endpoint, caller);
  }

  /// Полный in-memory стенд: transport pair + репозиторий.
  static Future<InMemoryDataServiceEnvironment> inMemory({
    DataRepository? repository,
    String serverLabel = 'DataResponder',
    String clientLabel = 'DataCaller',
  }) async {
    final (clientTransport, serverTransport) = RpcInMemoryTransport.pair();
    final repo = repository ?? InMemoryDataRepository();
    final server = createServer(
      transport: serverTransport,
      repository: repo,
      debugLabel: serverLabel,
    );
    await server.start();
    final client = createClient(
      transport: clientTransport,
      debugLabel: clientLabel,
    );
    return InMemoryDataServiceEnvironment(
      client: client,
      server: server,
      clientTransport: clientTransport,
      serverTransport: serverTransport,
    );
  }
}
