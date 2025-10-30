import 'package:rpc_dart_data/rpc_dart_data.dart';

Future<void> main() async {
  final statements = <({String sql, List<Object?> args})>[];
  final storage = DriftDataStorageAdapter.memory(
    statementObserver: (sql, args) {
      statements.add((sql: sql, args: List<Object?>.from(args)));
    },
  );
  final repository = DriftDataRepository(storage: storage);

  for (var i = 0; i < 5; i++) {
    final status = i.isEven ? 'open' : 'closed';
    await repository.create(
      CreateRecordRequest(
        collection: 'tasks',
        id: 'task-' + i.toString(),
        payload: {'priority': i, 'status': status},
      ),
    );
  }

  statements.clear();
  final response = await repository.list(
    const ListRecordsRequest(
      collection: 'tasks',
      filter: RecordFilter(equals: {'status': 'open'}),
      sort: SortOrder(field: 'priority', descending: true),
      options: QueryOptions(limit: 1, offset: 1, includeTotalCount: true),
    ),
  );

  print('totalCount: ' + response.totalCount.toString());
  print('records: ' + response.records.map((r) => r.id).toList().toString());
  print('nextCursor: ' + (response.nextCursor ?? 'null'));
  for (final entry in statements) {
    print('SQL: ' + entry.sql);
    print('ARGS: ' + entry.args.toString());
  }

  await repository.dispose();
}
