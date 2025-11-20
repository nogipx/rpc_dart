import 'dart:async';
import 'dart:collection';

import 'package:rpc_dart/rpc_dart.dart';

import '../models.dart';
import 'data_contract.dart';

class DataServiceCaller extends RpcCallerContract
    implements IDataServiceContract {
  DataServiceCaller(
    RpcCallerEndpoint endpoint, {
    RpcDataTransferMode mode = RpcDataTransferMode.codec,
  }) : super(
          IDataServiceContract.name,
          endpoint,
          dataTransferMode: mode,
        );

  Future<CreateRecordResponse> createRecord(
    CreateRecordRequest request, {
    RpcContext? context,
  }) {
    return callUnary(
      methodName: IDataServiceContract.createRecord,
      request: request,
      requestCodec: createRequestCodec,
      responseCodec: createResponseCodec,
      context: context,
    );
  }

  Future<GetRecordResponse> getRecord(
    GetRecordRequest request, {
    RpcContext? context,
  }) {
    return callUnary(
      methodName: IDataServiceContract.getRecord,
      request: request,
      requestCodec: getRequestCodec,
      responseCodec: getResponseCodec,
      context: context,
    );
  }

  Future<ListRecordsResponse> listRecords(
    ListRecordsRequest request, {
    RpcContext? context,
  }) {
    return callUnary(
      methodName: IDataServiceContract.listRecords,
      request: request,
      requestCodec: listRequestCodec,
      responseCodec: listResponseCodec,
      context: context,
    );
  }

  Future<UpdateRecordResponse> updateRecord(
    UpdateRecordRequest request, {
    RpcContext? context,
  }) {
    return callUnary(
      methodName: IDataServiceContract.updateRecord,
      request: request,
      requestCodec: updateRequestCodec,
      responseCodec: updateResponseCodec,
      context: context,
    );
  }

  Future<PatchRecordResponse> patchRecord(
    PatchRecordRequest request, {
    RpcContext? context,
  }) {
    return callUnary(
      methodName: IDataServiceContract.patchRecord,
      request: request,
      requestCodec: patchRequestCodec,
      responseCodec: patchResponseCodec,
      context: context,
    );
  }

  Future<DeleteRecordResponse> deleteRecord(
    DeleteRecordRequest request, {
    RpcContext? context,
  }) {
    return callUnary(
      methodName: IDataServiceContract.deleteRecord,
      request: request,
      requestCodec: deleteRequestCodec,
      responseCodec: deleteResponseCodec,
      context: context,
    );
  }

  Future<DeleteCollectionResponse> deleteCollection(
    DeleteCollectionRequest request, {
    RpcContext? context,
  }) {
    return callUnary(
      methodName: IDataServiceContract.deleteCollection,
      request: request,
      requestCodec: deleteCollectionRequestCodec,
      responseCodec: deleteCollectionResponseCodec,
      context: context,
    );
  }

  Future<BulkUpsertResponse> bulkUpsert(
    Stream<DataRecord> records, {
    RpcContext? context,
  }) {
    return callClientStream(
      methodName: IDataServiceContract.bulkUpsert,
      requests: records,
      requestCodec: recordCodec,
      responseCodec: bulkUpsertResponseCodec,
      context: context,
    );
  }

  Future<BulkDeleteResponse> bulkDelete(
    BulkDeleteRequest request, {
    RpcContext? context,
  }) {
    return callUnary(
      methodName: IDataServiceContract.bulkDelete,
      request: request,
      requestCodec: bulkDeleteRequestCodec,
      responseCodec: bulkDeleteResponseCodec,
      context: context,
    );
  }

  Future<ExportSnapshotResponse> exportSnapshot(
    ExportSnapshotRequest request, {
    RpcContext? context,
  }) {
    return callUnary(
      methodName: IDataServiceContract.exportSnapshot,
      request: request,
      requestCodec: exportRequestCodec,
      responseCodec: exportResponseCodec,
      context: context,
    );
  }

  Future<ExportDatabaseResponse> exportDatabase(
    ExportDatabaseRequest request, {
    RpcContext? context,
  }) {
    return callUnary(
      methodName: IDataServiceContract.exportDatabase,
      request: request,
      requestCodec: exportDatabaseRequestCodec,
      responseCodec: exportDatabaseResponseCodec,
      context: context,
    );
  }

  Future<ImportDatabaseResponse> importDatabase(
    ImportDatabaseRequest request, {
    RpcContext? context,
  }) {
    return callUnary(
      methodName: IDataServiceContract.importDatabase,
      request: request,
      requestCodec: importDatabaseRequestCodec,
      responseCodec: importDatabaseResponseCodec,
      context: context,
    );
  }

  Future<SearchRecordsResponse> searchRecords(
    SearchRecordsRequest request, {
    RpcContext? context,
  }) {
    return callUnary(
      methodName: IDataServiceContract.searchRecords,
      request: request,
      requestCodec: searchRequestCodec,
      responseCodec: searchResponseCodec,
      context: context,
    );
  }

  Future<AggregateMetricsResponse> aggregateMetrics(
    AggregateMetricsRequest request, {
    RpcContext? context,
  }) {
    return callUnary(
      methodName: IDataServiceContract.aggregateMetrics,
      request: request,
      requestCodec: aggregateRequestCodec,
      responseCodec: aggregateResponseCodec,
      context: context,
    );
  }

  Future<CreateCollectionIndexResponse> createCollectionIndex(
    CreateCollectionIndexRequest request, {
    RpcContext? context,
  }) {
    return callUnary(
      methodName: IDataServiceContract.createCollectionIndex,
      request: request,
      requestCodec: createIndexRequestCodec,
      responseCodec: createIndexResponseCodec,
      context: context,
    );
  }

  Future<DeleteCollectionIndexResponse> deleteCollectionIndex(
    DeleteCollectionIndexRequest request, {
    RpcContext? context,
  }) {
    return callUnary(
      methodName: IDataServiceContract.deleteCollectionIndex,
      request: request,
      requestCodec: deleteIndexRequestCodec,
      responseCodec: deleteIndexResponseCodec,
      context: context,
    );
  }

  Stream<DataChangeEvent> watchChanges(
    WatchChangesRequest request, {
    RpcContext? context,
  }) {
    return callServerStream(
      methodName: IDataServiceContract.watchChanges,
      request: request,
      requestCodec: watchRequestCodec,
      responseCodec: changeEventCodec,
      context: context,
    );
  }

  Stream<SyncChangeResponse> syncChanges(
    Stream<SyncChangeRequest> requests, {
    RpcContext? context,
  }) {
    return callBidirectionalStream(
      methodName: IDataServiceContract.syncChanges,
      requests: requests,
      requestCodec: syncRequestCodec,
      responseCodec: syncResponseCodec,
      context: context,
    );
  }

  /// Удобный helper для постраничного обхода коллекции.
  Future<List<DataRecord>> listAllRecords(
    String collection, {
    RecordFilter? filter,
    SortOrder? sort,
    RpcContext? context,
  }) async {
    final aggregated = <DataRecord>[];
    String? cursor;
    do {
      final response = await listRecords(
        ListRecordsRequest(
          collection: collection,
          filter: filter,
          sort: sort,
          options: QueryOptions(limit: 50, cursor: cursor),
        ),
        context: context,
      );
      aggregated.addAll(response.records);
      cursor = response.nextCursor;
    } while (cursor != null);
    return aggregated;
  }

  /// Helper, который отправляет изменения и ждет первый ack.
  Future<SyncChangeResponse> pushAndAwaitAck(
    SyncChangeRequest request, {
    RpcContext? context,
  }) async {
    final controller = StreamController<SyncChangeRequest>();
    controller.add(request);
    await controller.close();
    return await syncChanges(controller.stream, context: context).first;
  }
}

String _defaultSessionId() =>
    'sess-${DateTime.now().microsecondsSinceEpoch.toRadixString(16)}';

final class _PendingRequest {
  _PendingRequest(this.commandId, this.request, this.order);

  final String commandId;
  final SyncChangeRequest request;
  final int order;
}

/// In-memory очередь команд для офлайн-режима. Клиент может складывать
/// команды, а затем при появлении соединения воспроизвести их через
/// `syncChanges`, получив подтверждения и конфликты.
class OfflineCommandQueue {
  OfflineCommandQueue(
    this._caller, {
    String? sessionId,
    DateTime Function()? clock,
    void Function(Object error, StackTrace stackTrace)? onError,
  })  : _clock = clock ?? (() => DateTime.now().toUtc()),
        _sessionId = sessionId ?? _defaultSessionId(),
        _onError = onError,
        _requestController = StreamController<SyncChangeRequest>();

  final DataServiceCaller _caller;
  final String _sessionId;
  final DateTime Function() _clock;
  final void Function(Object error, StackTrace stackTrace)? _onError;
  final StreamController<SyncChangeRequest> _requestController;
  final Queue<_PendingRequest> _queued = Queue<_PendingRequest>();
  final Map<String, _PendingRequest> _inFlight = {};
  final Map<String, Completer<SyncChangeResponse>> _pending = {};
  StreamSubscription<SyncChangeResponse>? _subscription;
  bool _connected = false;
  int _commandSequence = 0;
  int _requestSequence = 0;
  RpcContext? _context;

  /// Идентификатор клиентской сессии, общий для всех команд очереди.
  String get sessionId => _sessionId;

  /// Число команд, ожидающих подтверждения (в полете и в очереди).
  int get pendingCommands => _pending.length;

  /// Признак активного RPC-подключения к `syncChanges`.
  bool get isConnected => _connected;

  /// Команды, ожидающие отправки (можно сериализовать для хранения на диске).
  Iterable<DataCommand> get queuedCommands =>
      _queued.map((entry) => entry.request.command);

  /// Команды, уже отправленные, но ещё не подтверждённые сервером.
  Iterable<DataCommand> get inFlightCommands =>
      _inFlight.values.map((entry) => entry.request.command);

  Future<void> start({RpcContext? context}) async {
    if (_connected) {
      return;
    }
    _context = context ?? _context;
    _subscription = _caller
        .syncChanges(_requestController.stream, context: _context)
        .listen(
          _handleResponse,
          onError: _handleStreamError,
          onDone: _handleDone,
        );
    _connected = true;
    _flushQueued();
  }

  Future<void> stop() async {
    if (!_connected) {
      return;
    }
    await _subscription?.cancel();
    _subscription = null;
    _connected = false;
    _requeueInFlight();
  }

  Future<void> dispose() async {
    await stop();
    await _requestController.close();
  }

  /// Сформировать команду на создание, не отправляя её.
  DataCommand buildCreateCommand(CreateRecordRequest request) =>
      _buildCommand(DataCommandType.create, request.toJson());

  /// Сформировать команду на обновление.
  DataCommand buildUpdateCommand(UpdateRecordRequest request) =>
      _buildCommand(DataCommandType.update, request.toJson());

  /// Сформировать команду на патч.
  DataCommand buildPatchCommand(PatchRecordRequest request) =>
      _buildCommand(DataCommandType.patch, request.toJson());

  /// Сформировать команду на удаление.
  DataCommand buildDeleteCommand(DeleteRecordRequest request) =>
      _buildCommand(DataCommandType.delete, request.toJson());

  /// Добавить команду создания и, при необходимости, автоматически стартовать
  /// синхронизацию.
  Future<SyncChangeResponse> enqueueCreate(
    CreateRecordRequest request, {
    bool resolveConflicts = true,
    RpcContext? context,
    bool autoStart = true,
  }) {
    return enqueueCommand(
      buildCreateCommand(request),
      resolveConflicts: resolveConflicts,
      context: context,
      autoStart: autoStart,
    );
  }

  Future<SyncChangeResponse> enqueueUpdate(
    UpdateRecordRequest request, {
    bool resolveConflicts = true,
    RpcContext? context,
    bool autoStart = true,
  }) {
    return enqueueCommand(
      buildUpdateCommand(request),
      resolveConflicts: resolveConflicts,
      context: context,
      autoStart: autoStart,
    );
  }

  Future<SyncChangeResponse> enqueuePatch(
    PatchRecordRequest request, {
    bool resolveConflicts = true,
    RpcContext? context,
    bool autoStart = true,
  }) {
    return enqueueCommand(
      buildPatchCommand(request),
      resolveConflicts: resolveConflicts,
      context: context,
      autoStart: autoStart,
    );
  }

  Future<SyncChangeResponse> enqueueDelete(
    DeleteRecordRequest request, {
    bool resolveConflicts = true,
    RpcContext? context,
    bool autoStart = true,
  }) {
    return enqueueCommand(
      buildDeleteCommand(request),
      resolveConflicts: resolveConflicts,
      context: context,
      autoStart: autoStart,
    );
  }

  /// Переиграть заранее сформированную команду (например, из локального кеша).
  Future<SyncChangeResponse> enqueueCommand(
    DataCommand command, {
    bool resolveConflicts = true,
    RpcContext? context,
    bool autoStart = true,
  }) async {
    if (_pending.containsKey(command.commandId)) {
      throw StateError('Command ${command.commandId} is already pending');
    }

    if (context != null) {
      _context = context;
    }

    final requestId = _nextRequestId();
    final request = SyncChangeRequest(
      requestId: requestId,
      command: command,
      resolveConflicts: resolveConflicts,
    );

    final completer = Completer<SyncChangeResponse>();
    _pending[command.commandId] = completer;

    final pending = _PendingRequest(
      command.commandId,
      request,
      // Используем текущее значение счетчика (уже инкрементирован _nextRequestId),
      // чтобы порядок совпадал с номером requestId.
      _requestSequence,
    );
    _queued.addLast(pending);

    if (autoStart) {
      await _ensureConnection();
      _flushQueued();
    }

    return completer.future;
  }

  /// Явно отправить накопленные команды, если соединение уже установлено.
  Future<void> flushPending() async {
    await _ensureConnection();
    _flushQueued();
  }

  DataCommand _buildCommand(
    DataCommandType type,
    Map<String, dynamic> payload,
  ) {
    return DataCommand(
      commandId: _nextCommandId(),
      sessionId: _sessionId,
      type: type,
      payload: payload,
      issuedAt: _clock(),
    );
  }

  Future<void> _ensureConnection() async {
    if (_connected) {
      return;
    }
    await start(context: _context);
  }

  void _flushQueued() {
    if (!_connected) {
      return;
    }
    while (_queued.isNotEmpty) {
      final pending = _queued.removeFirst();
      _inFlight[pending.commandId] = pending;
      _requestController.add(pending.request);
    }
  }

  void _handleResponse(SyncChangeResponse response) {
    final inFlight = _inFlight.remove(response.commandId);
    final completer = _pending.remove(response.commandId);
    if (completer != null && !completer.isCompleted) {
      completer.complete(response);
    }
    if (inFlight == null && completer == null) {
      // Ответ на неизвестную команду — игнорируем, но пересинхронизация
      // может потребоваться вручную.
    }
  }

  void _handleStreamError(Object error, StackTrace stackTrace) {
    _requeueInFlight();
    _connected = false;
    _subscription = null;
    _onError?.call(error, stackTrace);
  }

  void _handleDone() {
    _requeueInFlight();
    _connected = false;
    _subscription = null;
  }

  void _requeueInFlight() {
    final toReplay = _inFlight.values.toList()
      ..sort((a, b) => b.order.compareTo(a.order));
    for (final pending in toReplay) {
      _queued.addFirst(pending);
    }
    _inFlight.clear();
  }

  String _nextCommandId() => '$sessionId-cmd-${++_commandSequence}';

  String _nextRequestId() => '$sessionId-req-${++_requestSequence}';
}
