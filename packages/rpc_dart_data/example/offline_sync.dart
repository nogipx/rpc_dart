import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_data/rpc_dart_data.dart';
import 'package:rpc_dart_transports/rpc_dart_transports.dart';

// Пример офлайн-репликации: очередь команд + последующая синхронизация.
Future<void> main() async {
  final env = DataServiceFactory.createClient(
    transport: await RpcHttp2CallerTransport.connect(
      host: '127.0.0.1',
      port: 8080,
    ),
  );
  final client = env;
  final ctx = RpcContext.withHeaders({'authorization': 'Bearer dev'});

  final queue = OfflineCommandQueue(client.rawCaller, sessionId: 'device-123');

  // Подготовим несколько команд (создание двух заметок и патч первой).
  final c1 = queue.buildCreateCommand(
    const CreateRecordRequest(
        collection: 'notes', payload: {'title': 'Draft A'}),
  );
  final c2 = queue.buildCreateCommand(
    const CreateRecordRequest(
        collection: 'notes', payload: {'title': 'Draft B'}),
  );

  // Сериализация для условного локального хранения.
  final stored = [c1.toJson(), c2.toJson()];

  // Восстановим и enqueue без автозапуска канала.
  final futures = <Future<SyncChangeResponse>>[];
  for (final json in stored) {
    futures.add(queue.enqueueCommand(DataCommand.fromJson(json),
        autoStart: false, context: ctx));
  }

  // Запускаем syncChanges канал единожды.
  await queue.start(context: ctx);
  await queue.flushPending();

  final results = await Future.wait(futures);
  for (final r in results) {
    print('Applied command=${r.commandId} applied=${r.applied}');
  }

  // Патч первой записи через pushAndAwaitAck (удобный helper caller-а)
  final firstId = results.first.record!.id;
  final patchResponse = await client.rawCaller.pushAndAwaitAck(
    SyncChangeRequest(
      requestId: 'req-local-1',
      command: queue.buildPatchCommand(
        PatchRecordRequest(
          collection: 'notes',
          id: firstId,
          expectedVersion: results.first.record!.version,
          patch: const RecordPatch(set: {'flagged': true}),
        ),
      ),
    ),
    context: ctx,
  );
  print('Patch applied=${patchResponse.applied}');

  // Просмотр финального списка.
  final all = await client.list(collection: 'notes', context: ctx);
  print('Final notes: ${all.records.length}');

  await queue.dispose();
  await env.close();
}
