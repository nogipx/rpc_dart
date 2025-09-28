import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';

import 'data_caller.dart';
import 'data_contract.dart';
import 'data_repository.dart';
import 'data_responder.dart';
import 'models.dart';

Future<void> main() async {
  final (clientTransport, serverTransport) = RpcInMemoryTransport.pair();

  final responderEndpoint = RpcResponderEndpoint(
    transport: serverTransport,
    debugLabel: 'DataResponder',
  );
  final repository = InMemoryDataRepository();
  final responder = DataServiceResponder(repository: repository);
  responderEndpoint.registerServiceContract(responder);
  responderEndpoint.start();

  final callerEndpoint = RpcCallerEndpoint(
    transport: clientTransport,
    debugLabel: 'DataCaller',
  );
  final client = DataServiceCaller(callerEndpoint);

  final baseContext = RpcContext.withHeaders({
    'x-tenant-id': 'tenant-acme',
    'authorization': 'Bearer development-token',
  }).withTraceId('trace-${DateTime.now().millisecondsSinceEpoch}');

  final createResponse = await client.createRecord(
    const CreateRecordRequest(
      collection: 'articles',
      payload: {
        'title': 'Hello RPC',
        'views': 1,
        'tags': ['rpc', 'dart'],
      },
    ),
    context: baseContext,
  );
  final created = createResponse.record;
  expect(created.version, 1, reason: 'Newly created record should start with version 1');

  final listResponse = await client.listRecords(
    ListRecordsRequest(
      collection: 'articles',
      filter: const RecordFilter(equals: {'title': 'Hello RPC'}),
      options: const QueryOptions(limit: 10, includeTotalCount: true),
    ),
    context: baseContext,
  );
  expect(listResponse.totalCount, 1, reason: 'List should contain the created record');

  final updatedRecord = created.copyWith(
    payload: {
      ...created.payload,
      'views': 2,
      'description': 'An end-to-end RPC example',
    },
    version: created.version + 1,
    updatedAt: DateTime.now().toUtc(),
  );
  final updateResponse = await client.updateRecord(
    UpdateRecordRequest(record: updatedRecord),
    context: baseContext,
  );
  expect(updateResponse.record.version, 2, reason: 'Version should increment on update');

  final searchResponse = await client.searchRecords(
    const SearchRecordsRequest(
      collection: 'articles',
      query: 'rpc',
      options: QueryOptions(limit: 5),
    ),
    context: baseContext,
  );
  expect(searchResponse.totalHits, 1, reason: 'Search should find the updated record');

  final watchCancellation = RpcCancellationToken();
  final watchContext = baseContext.withCancellation(watchCancellation);
  final watchSubscription = client
      .watchChanges(
        const WatchChangesRequest(collection: 'articles'),
        context: watchContext,
      )
      .listen((event) {
    print('🔔 change event: ${event.type} ${event.id} cursor=${event.cursor}');
  });

  await client.patchRecord(
    PatchRecordRequest(
      collection: 'articles',
      id: created.id,
      expectedVersion: 2,
      patch: const RecordPatch(set: {'views': 3}, unset: ['description']),
    ),
    context: baseContext,
  );

  await Future<void>.delayed(const Duration(milliseconds: 200));
  watchCancellation.cancel('scenario complete');
  await watchSubscription.cancel();

  final offlineRecord = DataRecord(
    id: 'offline-1',
    collection: 'articles',
    payload: const {'title': 'Offline note', 'views': 0},
    version: 1,
    createdAt: DateTime.now().toUtc(),
    updatedAt: DateTime.now().toUtc(),
  );
  final syncController = StreamController<SyncChangeRequest>();
  final syncResponses = client.syncChanges(syncController.stream, context: baseContext);
  syncController.add(
    SyncChangeRequest(
      requestId: 'req-1',
      event: DataChangeEvent(
        type: DataChangeType.created,
        collection: offlineRecord.collection,
        id: offlineRecord.id,
        record: offlineRecord,
        version: offlineRecord.version,
        cursor: 'client-cursor',
        occurredAt: offlineRecord.updatedAt,
      ),
    ),
  );
  await syncController.close();
  final firstAck = await syncResponses.first;
  expect(firstAck.applied, true, reason: 'Offline change must be applied');

  final snapshot = await client.exportSnapshot(
    const ExportSnapshotRequest(collection: 'articles'),
    context: baseContext,
  );
  expect(snapshot.records.length >= 2, true,
      reason: 'Snapshot should include both online and synced offline records');

  try {
    await client.deleteRecord(
      DeleteRecordRequest(
        collection: 'articles',
        id: created.id,
        expectedVersion: 1,
      ),
      context: baseContext,
    );
  } on RpcError catch (error) {
    print('⚠️ Expected delete conflict: ${error.code} -> ${error.message}');
  }

  await client.bulkDelete(
    const BulkDeleteRequest(collection: 'articles', ids: ['offline-1']),
    context: baseContext,
  );

  await callerEndpoint.close();
  await responderEndpoint.close();
  await repository.dispose();

  print('✅ Scenario finished successfully.');
  print('💡 To switch to a real transport, replace RpcInMemoryTransport.pair()');
  print('    with transports from rpc_dart_transports (HTTP/2, WebSocket, etc.).');
}

void expect(Object? actual, Object? matcher, {String? reason}) {
  if (actual != matcher) {
    throw StateError(
      'Expectation failed: $actual != $matcher${reason != null ? ' ($reason)' : ''}',
    );
  }
}
