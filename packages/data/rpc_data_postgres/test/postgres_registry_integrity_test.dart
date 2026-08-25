// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:io';

import 'package:postgres/postgres.dart';
import 'package:rpc_data_postgres/rpc_data_postgres.dart';
import 'package:test/test.dart';

import 'nanoid.dart';

/// Override with RPC_PG_URL to point at a throwaway instance; the default
/// is the local dev database these tests were written against.
final _url =
    Platform.environment['RPC_PG_URL'] ??
    'postgresql://postgres:00000000@localhost:5434/postgres?sslmode=disable';
const _schema = 'public';
const _prefix = 'ptint_';

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

/// The registry state a torn teardown leaves behind: a registration whose
/// table is gone.
///
/// It is written directly rather than produced by killing a delete midway,
/// because the point of the tests below is what the adapter does when it finds
/// one — from a partial restore, a manual DROP, or a delete cut short by a
/// build that predates the transaction.
void main() {
  group('registry integrity', () {
    late Connection connection;
    final registry = '"$_schema"."${_prefix}s_collection_registry"';
    final created = <String>[];

    Future<PostgresDataStorageAdapter> makeAdapter({
      PostgresIntegrityReporter? onIntegrityIssue,
    }) => PostgresDataStorageAdapter.connect(
      endpoint: _endpoint(),
      schema: _schema,
      tablePrefix: _prefix,
      settings: const ConnectionSettings(sslMode: SslMode.disable),
      onIntegrityIssue: onIntegrityIssue,
    );

    /// A collection name no other test shares, remembered so the group leaves
    /// the database as it found it — an orphan outliving its test would show
    /// up in the next test's integrity report.
    String freshCollection(String prefix) {
      final collection = '${prefix}_${NanoId.generate()}';
      created.add(collection);
      return collection;
    }

    Future<void> orphanRegistration(String collection) async {
      await connection.execute(
        Sql.named(
          'INSERT INTO $registry (collection, table_name) VALUES (@c, @t)',
        ),
        parameters: {
          'c': collection,
          't': '"$_schema"."${_prefix}c_${collection.replaceAll('-', '_')}"',
        },
      );
    }

    Future<int> registrationsOf(String collection) async {
      final rows = await connection.execute(
        Sql.named('SELECT 1 FROM $registry WHERE collection = @c'),
        parameters: {'c': collection},
      );
      return rows.length;
    }

    setUp(() async {
      connection = await Connection.openFromUrl(_url);
      created.clear();
      // Materialise the registry so a test can seed it before any adapter runs.
      await (await makeAdapter()).dispose();
    });

    tearDown(() async {
      final adapter = await makeAdapter();
      for (final collection in created) {
        await adapter.deleteCollection(collection);
      }
      await adapter.dispose();
      await connection.close();
    });

    /// A collection this process cannot see must not stop it from serving the
    /// ones it can. This threw, so one dropped table failed every boot after
    /// it — the whole server, not the one collection.
    test('a registration with no table does not fail startup', () async {
      final collection = freshCollection('orphan');
      await orphanRegistration(collection);

      final reported = <String>[];
      final adapter = await makeAdapter(onIntegrityIssue: reported.add);

      // Scoped to this collection: the target database is shared, and what
      // matters is that the adapter came up at all while reporting the damage.
      expect(reported.where((m) => m.contains(collection)), hasLength(1));
      await adapter.dispose();
    });

    test('a collection whose table is gone reads as empty', () async {
      final collection = freshCollection('orphan');
      await orphanRegistration(collection);
      final adapter = await makeAdapter();

      expect(await adapter.readRecord(collection, 'anything'), isNull);
      expect(await adapter.readCollection(collection), isEmpty);
      await adapter.dispose();
    });

    test('writing to it recreates the table', () async {
      final collection = freshCollection('orphan');
      await orphanRegistration(collection);
      final adapter = await makeAdapter();

      final now = DateTime.now().toUtc();
      await adapter.writeRecord(
        DataRecord(
          id: 'a',
          collection: collection,
          payload: {'v': 1},
          version: 1,
          createdAt: now,
          updatedAt: now,
        ),
      );

      expect((await adapter.readRecord(collection, 'a'))?.payload['v'], 1);
      await adapter.deleteCollection(collection);
      await adapter.dispose();
    });

    test('deleting it clears the stale registration', () async {
      final collection = freshCollection('orphan');
      await orphanRegistration(collection);
      final adapter = await makeAdapter();

      expect(await adapter.deleteCollection(collection), isTrue);
      expect(await registrationsOf(collection), 0);
      await adapter.dispose();
    });

    /// The bug at the source: the teardown dropped the table and deleted the
    /// registration as separate statements, so an interruption between them
    /// produced exactly the orphan the tests above have to cope with.
    test('deleteCollection leaves neither table nor registration', () async {
      final collection = freshCollection('teardown');
      final adapter = await makeAdapter();

      final now = DateTime.now().toUtc();
      await adapter.writeRecord(
        DataRecord(
          id: 'a',
          collection: collection,
          payload: {'v': 1},
          version: 1,
          createdAt: now,
          updatedAt: now,
        ),
      );
      expect(await registrationsOf(collection), 1);

      await adapter.deleteCollection(collection);

      expect(await registrationsOf(collection), 0);
      final table = await connection.execute(
        Sql.named(
          'SELECT 1 FROM pg_tables WHERE schemaname = @s AND tablename = @t',
        ),
        parameters: {
          's': _schema,
          't': '${_prefix}c_${collection.replaceAll('-', '_')}',
        },
      );
      expect(table, isEmpty);

      // And a fresh adapter still boots — the pair is consistent either way.
      final reported = <String>[];
      final next = await makeAdapter(onIntegrityIssue: reported.add);
      expect(reported.where((m) => m.contains(collection)), isEmpty);
      await next.dispose();
      await adapter.dispose();
    });
  });
}
