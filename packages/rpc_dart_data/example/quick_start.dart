import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_data/rpc_dart_data.dart';

// Quick start: минимальный CRUD + watch.
Future<void> main() async {
  final env = await DataServiceFactory.inMemory();
  final client = env.client;
  final ctx = RpcContext.withHeaders({
    'x-tenant-id': 'demo-tenant',
    'authorization': 'Bearer dev',
  });

  final created = await client.create(
    collection: 'notes',
    payload: {'title': 'First note', 'done': false},
    context: ctx,
  );
  print('Created id=${created.id} v=${created.version}');

  final list = await client.list(collection: 'notes', context: ctx);
  print('Total notes: ${list.records.length}');

  final sub = client
      .watchChanges(collection: 'notes', context: ctx)
      .listen((e) => print('Change: ${e.type} id=${e.id} v=${e.version}'));

  await client.patch(
    collection: 'notes',
    id: created.id,
    expectedVersion: created.version,
    patch: const RecordPatch(set: {'done': true}),
    context: ctx,
  );

  await Future<void>.delayed(const Duration(milliseconds: 100));
  await sub.cancel();
  await env.dispose();
}
