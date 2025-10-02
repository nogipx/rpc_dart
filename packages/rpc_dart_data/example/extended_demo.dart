import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_data/rpc_dart_data.dart';

/// Расширенный демонстрационный сценарий использования фасада DataService.
/// 1. CRUD
/// 2. Search + Aggregate + Snapshot
/// 3. Streaming (watch) + отмена
/// 4. Offline очередь команд (OfflineCommandQueue)
/// 5. Конфликты версий (patch/delete)
Future<void> main() async {
  final env = await DataServiceFactory.inMemory();
  final client = env.client;
  final baseContext = RpcContext.withHeaders({
    'authorization': 'Bearer development-token',
  }).withTraceId('trace-${DateTime.now().millisecondsSinceEpoch}');

  final created = await client.create(
    collection: 'articles',
    payload: {
      'title': 'Hello RPC',
      'views': 1,
      'tags': ['rpc', 'dart'],
    },
    context: baseContext,
  );

  final listed = await client.list(
    collection: 'articles',
    filter: const RecordFilter(equals: {'title': 'Hello RPC'}),
    options: const QueryOptions(limit: 10, includeTotalCount: true),
    context: baseContext,
  );
  _check(listed.totalCount == 1, 'Should have exact 1 record after create');

  final updated = await client.update(
    collection: created.collection,
    id: created.id,
    expectedVersion: created.version,
    payload: {
      ...created.payload,
      'views': 2,
      'description': 'An end-to-end RPC example',
    },
    context: baseContext,
  );
  _check(updated.version == 2, 'Version after update must be 2');

  final cancelToken = RpcCancellationToken();
  final watchSub = client
      .watchChanges(
          collection: 'articles',
          context: baseContext.withCancellation(cancelToken))
      .listen((e) => print(
          '🔔 change: ${e.type} id=${e.id} v=${e.version} cursor=${e.cursor}'));

  final patched = await client.patch(
    collection: 'articles',
    id: created.id,
    expectedVersion: 2,
    patch: const RecordPatch(set: {'views': 3}, unset: ['description']),
    context: baseContext,
  );
  _check(patched.version == 3, 'Patch increments version');

  final search = await client.search(
    collection: 'articles',
    query: 'rpc',
    context: baseContext,
  );
  _check(search.totalHits == 1, 'Search should find 1 record');

  await client.create(
    collection: 'articles',
    payload: {'title': 'Another Article', 'views': 10},
    context: baseContext,
  );

  final metrics = await client.aggregate(
    collection: 'articles',
    metrics: {
      'countAll': 'count',
      'sumViews': 'sum:views',
      'avgViews': 'avg:views',
    },
    context: baseContext,
  );
  print('📊 metrics: ${metrics.metrics}');

  final snapshot =
      await client.exportSnapshot(collection: 'articles', context: baseContext);
  print('Snapshot size: ${snapshot.records.length}');

  try {
    await client.patch(
      collection: 'articles',
      id: created.id,
      expectedVersion: 2, // ожидаемо конфликт (текущая 3)
      patch: const RecordPatch(set: {'views': 999}),
      context: baseContext,
    );
    throw StateError('Conflict expected but not thrown');
  } on RpcDataError catch (e) {
    print('⚠️ patch conflict ok (typed): ${e.code}');
  } on RpcException catch (e) {
    print('⚠️ patch conflict ok (generic RpcException): ${e.message}');
  } catch (e) {
    final msg = e.toString();
    if (msg.contains('Expected version') || msg.contains('VERSION_CONFLICT')) {
      print('⚠️ patch conflict ok (wrapped): $msg');
    } else {
      rethrow; // не наш ожидаемый конфликт
    }
  }

  final offlineQueue =
      OfflineCommandQueue(client.rawCaller, sessionId: 'mobile-session');
  final offlineCreate = offlineQueue.buildCreateCommand(
    const CreateRecordRequest(
        collection: 'articles', payload: {'title': 'Offline note', 'views': 0}),
  );
  final ackFuture = offlineQueue.enqueueCommand(offlineCreate,
      autoStart: false, context: baseContext);
  await offlineQueue.start(context: baseContext);
  await offlineQueue.flushPending();
  final ack = await ackFuture;
  print('Offline applied=${ack.applied} id=${ack.record?.id}');

  cancelToken.cancel('demo done');
  await watchSub.cancel();

  final deleted = await client.bulkDelete(
    collection: 'articles',
    ids: [ack.record!.id],
    context: baseContext,
  );
  print('Bulk deleted: $deleted');

  try {
    await client.delete(
      collection: 'articles',
      id: created.id,
      expectedVersion: 1, // конфликт версии
      context: baseContext,
    );
    throw StateError('Delete conflict expected but not thrown');
  } on RpcDataError catch (e) {
    print('⚠️ delete conflict ok (typed): ${e.code}');
  } on RpcException catch (e) {
    print('⚠️ delete conflict ok (generic RpcException): ${e.message}');
  } catch (e) {
    final msg = e.toString();
    if (msg.contains('Expected version') || msg.contains('VERSION_CONFLICT')) {
      print('⚠️ delete conflict ok (wrapped): $msg');
    } else {
      rethrow;
    }
  }

  final finalList =
      await client.list(collection: 'articles', context: baseContext);
  print('Final count: ${finalList.records.length}');

  await offlineQueue.dispose();
  await env.dispose();
  print('✅ Extended demo finished');
}

void _check(bool c, String m) {
  if (!c) throw StateError(m);
}
