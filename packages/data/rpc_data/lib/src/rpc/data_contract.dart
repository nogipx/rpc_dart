// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';

import '../models.dart';

part 'data_contract.g.dart';

/// Контракт сервиса данных с именем DataService.
@RpcService(
  name: 'DataService',
  transferMode: RpcDataTransferMode.codec,
  description: 'CRUD/поиск/схемы/экспорт для драйвер-агностичного хранилища',
)
abstract interface class IDataServiceContract implements IRpcContract {
  @RpcMethod.unary(
    name: 'createRecord',
    description: 'Создание новой записи с проверкой прав и дедлайна',
  )
  Future<CreateRecordResponse> createRecord(
    CreateRecordRequest request, {
    RpcContext? context,
  });

  @RpcMethod.unary(
    name: 'getRecord',
    description: 'Получение записи по идентификатору',
  )
  Future<GetRecordResponse> getRecord(
    GetRecordRequest request, {
    RpcContext? context,
  });

  @RpcMethod.unary(
    name: 'getRecords',
    description: 'Пакетное чтение записей коллекции по идентификаторам',
  )
  Future<GetRecordsResponse> getRecords(
    GetRecordsRequest request, {
    RpcContext? context,
  });

  @RpcMethod.unary(
    name: 'listRecords',
    description: 'Постраничный список с фильтрацией и сортировкой',
  )
  Future<ListRecordsResponse> listRecords(
    ListRecordsRequest request, {
    RpcContext? context,
  });

  @RpcMethod.unary(
    name: 'listCollections',
    description: 'Список существующих коллекций',
  )
  Future<ListCollectionsResponse> listCollections(
    ListCollectionsRequest request, {
    RpcContext? context,
  });

  @RpcMethod.unary(
    name: 'updateRecord',
    description: 'Полное обновление записи c оптимистической конкуренцией',
  )
  Future<UpdateRecordResponse> updateRecord(
    UpdateRecordRequest request, {
    RpcContext? context,
  });

  @RpcMethod.unary(
    name: 'patchRecord',
    description: 'Частичное обновление через RecordPatch',
  )
  Future<PatchRecordResponse> patchRecord(
    PatchRecordRequest request, {
    RpcContext? context,
  });

  @RpcMethod.unary(
    name: 'deleteRecord',
    description: 'Удаление с проверкой версии',
  )
  Future<DeleteRecordResponse> deleteRecord(
    DeleteRecordRequest request, {
    RpcContext? context,
  });

  @RpcMethod.unary(
    name: 'deleteCollection',
    description: 'Удаление коллекции и всех записей',
  )
  Future<DeleteCollectionResponse> deleteCollection(
    DeleteCollectionRequest request, {
    RpcContext? context,
  });

  @RpcMethod.clientStream(
    name: 'bulkUpsert',
    description: 'Пакетный upsert через клиентский стрим',
  )
  Future<BulkUpsertResponse> bulkUpsert(
    Stream<DataRecord> request, {
    RpcContext? context,
  });

  @RpcMethod.unary(
    name: 'bulkDelete',
    description: 'Массовое удаление записей',
  )
  Future<BulkDeleteResponse> bulkDelete(
    BulkDeleteRequest request, {
    RpcContext? context,
  });

  @RpcMethod.unary(
    name: 'exportSnapshot',
    description: 'Экспорт моментального снимка коллекции',
  )
  Future<ExportSnapshotResponse> exportSnapshot(
    ExportSnapshotRequest request, {
    RpcContext? context,
  });

  @RpcMethod.serverStream(
    name: 'exportDatabase',
    description: 'Полный экспорт базы данных (стрим NDJSON чанков)',
  )
  Stream<DatabaseChunk> exportDatabase(
    ExportDatabaseRequest request, {
    RpcContext? context,
  });

  @RpcMethod.bidirectionalStream(
    name: 'importDatabase',
    description: 'Импорт полной базы данных из NDJSON чанков с ACK прогрессом',
  )
  Stream<ImportProgress> importDatabase(
    Stream<DatabaseChunk> request, {
    RpcContext? context,
  });

  @RpcMethod.unary(
    name: 'searchRecords',
    description: 'Полнотекстовый поиск по коллекции',
  )
  Future<SearchRecordsResponse> searchRecords(
    SearchRecordsRequest request, {
    RpcContext? context,
  });

  @RpcMethod.unary(
    name: 'createCollectionIndex',
    description: 'Создание индексированного выражения для JSON-поля',
  )
  Future<CreateCollectionIndexResponse> createCollectionIndex(
    CreateCollectionIndexRequest request, {
    RpcContext? context,
  });

  @RpcMethod.unary(
    name: 'deleteCollectionIndex',
    description: 'Удаление индексированного выражения коллекции',
  )
  Future<DeleteCollectionIndexResponse> deleteCollectionIndex(
    DeleteCollectionIndexRequest request, {
    RpcContext? context,
  });

  @RpcMethod.serverStream(
    name: 'watchChanges',
    description: 'Стрим изменений коллекции с курсором',
  )
  Stream<DataChangeEvent> watchChanges(
    WatchChangesRequest request, {
    RpcContext? context,
  });

  @RpcMethod.unary(
    name: 'listSchemas',
    description: 'Список активных схем коллекций',
  )
  Future<ListSchemasResponse> listSchemas(
    ListSchemasRequest request, {
    RpcContext? context,
  });

  @RpcMethod.unary(
    name: 'getSchema',
    description: 'Получение схемы коллекции',
  )
  Future<GetSchemaResponse> getSchema(
    GetSchemaRequest request, {
    RpcContext? context,
  });

  @RpcMethod.unary(
    name: 'setSchemaPolicy',
    description: 'Установка политики схемы коллекции',
  )
  Future<SetSchemaPolicyResponse> setSchemaPolicy(
    SetSchemaPolicyRequest request, {
    RpcContext? context,
  });
}
