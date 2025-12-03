import 'dart:convert';
import 'dart:io';

import 'package:licensify/licensify.dart';
import 'package:rpc_dart_data/rpc_dart_data.dart';

/// Minimal in-memory transport with a file-backed SQLite adapter.
///
/// The SQLite file lives on disk, while the RPC transport between client and
/// server is in-memory for simplicity. Replace the transport with your own
/// network layer to expose the same repository remotely.
Future<void> main() async {
  final dbFile = File('notes.sqlite');
  if (dbFile.existsSync()) {
    dbFile.deleteSync();
  }

  final cipherKey = SqlCipherKey.fromPaserk(
    paserk: Licensify.generateEncryptionKey().toPaserk(),
  );
  final connection = await openFileDb(
    options: SqliteConnectionOptions(nativeFileName: dbFile.path),
    // Add your own PRAGMAs or WAL config here.
    sqliteSetup: (db) => db.execute('PRAGMA journal_mode=WAL;'),
    // To enable SQLCipher, also pass sqlCipherKey.
    // sqlCipherKey: cipherKey,
  );

  final storage = SqliteDataStorageAdapter.connection(connection);
  await storage.ensureReady();

  final env = await DataServiceFactory.inMemory(
    repository: SqliteDataRepository(storage: storage),
  );
  final client = env.client;

  final created = await client.create(
    collection: 'notes',
    payload: {'title': 'Hello', 'done': false},
  );
  print('created id=${created.id} v=${created.version}');

  final updated = await client.patch(
    collection: 'notes',
    id: created.id,
    expectedVersion: created.version,
    patch: const RecordPatch(set: {'done': true}),
  );
  print('patched id=${updated.id} v=${updated.version}');

  final listed = await client.list(
    collection: 'notes',
    options: const QueryOptions(limit: 10),
  );
  for (final note in listed.records) {
    print(
      'note ${note.id} title=${note.payload['title']} done=${note.payload['done']}',
    );
  }

  final export = await client.exportDatabase(includePayloadString: false);
  await for (final chunk in export.payloadStream!) {
    print(utf8.decode(chunk));
  }

  await env.dispose();
  await connection.close();
}
