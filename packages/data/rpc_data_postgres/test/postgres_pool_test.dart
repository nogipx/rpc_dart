// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'package:postgres/postgres.dart';
import 'package:rpc_data_postgres/rpc_data_postgres.dart';
import 'package:test/test.dart';

import 'nanoid.dart';

const _url =
    'postgresql://postgres:00000000@localhost:5433/postgres?sslmode=disable';
const _schema = 'public';
// Изолированный префикс, чтобы не пересекаться с другими тестами
const _prefix = 'ptpool_';

Endpoint _endpoint() {
  final uri = Uri.parse(_url);
  final userInfo = uri.userInfo.split(':');
  return Endpoint(
    host: uri.host,
    port: uri.port == 0 ? 5432 : uri.port,
    database: uri.pathSegments.first,
    username: userInfo.first,
    password: userInfo.length > 1 ? userInfo.sublist(1).join(':') : null,
  );
}

Pool<void> _makePool({int maxConnections = 3}) {
  return Pool.withEndpoints(
    [_endpoint()],
    settings: PoolSettings(
      maxConnectionCount: maxConnections,
      sslMode: SslMode.disable,
    ),
  );
}

void main() {
  group('PostgresDataStorageAdapter.withPool', () {
    late Pool<void> pool;
    final collections = <String>[];

    setUp(() {
      pool = _makePool();
      collections.clear();
    });

    tearDown(() async {
      // Чистим все коллекции, созданные в тесте
      for (final adapter in <PostgresDataStorageAdapter>[]) {
        for (final c in collections) {
          await adapter.deleteCollection(c);
        }
        await adapter.dispose();
      }
      await pool.close();
    });

    Future<PostgresDataStorageAdapter> makeAdapter() async {
      return PostgresDataStorageAdapter.withPool(
        pool,
        schema: _schema,
        tablePrefix: _prefix,
      );
    }

    test('withPool создаёт адаптер и выполняет базовые операции', () async {
      final col = 'pool_basic_${NanoId.generate()}';
      collections.add(col);
      final adapter = await makeAdapter();

      final repo = PostgresDataRepository(storage: adapter);

      final created = await repo.create(
        CreateRecordRequest(collection: col, payload: {'x': 1}),
      );
      final fetched = await repo.get(
        GetRecordRequest(collection: col, id: created.id),
      );

      expect(fetched?.payload['x'], equals(1));

      await adapter.deleteCollection(col);
      await adapter.dispose(); // пул не закрывается
    });

    test('dispose адаптера не закрывает пул — пул остаётся рабочим', () async {
      final col1 = 'pool_dispose1_${NanoId.generate()}';
      final col2 = 'pool_dispose2_${NanoId.generate()}';

      final adapter1 = await makeAdapter();
      await PostgresDataRepository(storage: adapter1).create(
        CreateRecordRequest(collection: col1, payload: {'n': 1}),
      );
      await adapter1.deleteCollection(col1);
      await adapter1.dispose(); // освобождаем первый адаптер

      // Пул должен оставаться рабочим — создаём второй адаптер на том же пуле
      final adapter2 = await makeAdapter();
      final repo2 = PostgresDataRepository(storage: adapter2);
      final created = await repo2.create(
        CreateRecordRequest(collection: col2, payload: {'n': 2}),
      );
      final fetched = await repo2.get(
        GetRecordRequest(collection: col2, id: created.id),
      );

      expect(fetched?.payload['n'], equals(2));

      await adapter2.deleteCollection(col2);
      await adapter2.dispose();
    });

    test('два адаптера на одном пуле работают независимо', () async {
      final col1 = 'pool_shared1_${NanoId.generate()}';
      final col2 = 'pool_shared2_${NanoId.generate()}';

      final adapter1 = await makeAdapter();
      final adapter2 = await makeAdapter();
      final repo1 = PostgresDataRepository(storage: adapter1);
      final repo2 = PostgresDataRepository(storage: adapter2);

      await repo1.create(
        CreateRecordRequest(collection: col1, payload: {'src': 'adapter1'}),
      );
      await repo2.create(
        CreateRecordRequest(collection: col2, payload: {'src': 'adapter2'}),
      );

      final list1 = await adapter1.readCollection(col1);
      final list2 = await adapter2.readCollection(col2);

      expect(list1.length, equals(1));
      expect(list1.first.payload['src'], equals('adapter1'));
      expect(list2.length, equals(1));
      expect(list2.first.payload['src'], equals('adapter2'));

      await adapter1.deleteCollection(col1);
      await adapter2.deleteCollection(col2);
      await adapter1.dispose();
      await adapter2.dispose();
    });

    test('параллельные запросы через пул выполняются корректно', () async {
      final col = 'pool_parallel_${NanoId.generate()}';
      final adapter = await makeAdapter();
      final repo = PostgresDataRepository(storage: adapter);

      // Прогреваем коллекцию: CREATE TABLE IF NOT EXISTS не является
      // атомарным между несколькими соединениями пула, поэтому таблица
      // должна быть создана до параллельных запросов.
      await repo.create(
        CreateRecordRequest(collection: col, payload: {'i': -1}),
      );

      // Параллельно создаём ещё 10 записей
      await Future.wait([
        for (var i = 0; i < 10; i++)
          repo.create(
            CreateRecordRequest(
              collection: col,
              payload: {'i': i},
            ),
          ),
      ]);

      final records = await adapter.readCollection(col);
      expect(records.length, equals(11)); // 1 прогрев + 10 параллельных
      expect(
        records.map((r) => r.payload['i'] as int).toSet(),
        containsAll({0, 1, 2, 3, 4, 5, 6, 7, 8, 9}),
      );

      await adapter.deleteCollection(col);
      await adapter.dispose();
    });

    test('executor адаптера имеет тип Session а не Connection', () async {
      final adapter = await makeAdapter();
      expect(adapter.executor, isA<Session>());
      expect(adapter.executor, isNot(isA<Connection>()));
      await adapter.dispose();
    });
  });
}
