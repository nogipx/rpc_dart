import 'dart:io';

import 'package:licensify/licensify.dart';
import 'package:path/path.dart' as p;
import 'package:rpc_dart_data/src/connection/connection_native.dart';
import 'package:rpc_dart_data/src/connection/options.dart';
import 'package:rpc_dart_data/src/sqlite_storage/sql_cipher.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;
import 'package:test/test.dart';

void main() {
  group('SQLCipher file I/O', () {
    late final String dbPath;

    setUp(() async {
      dbPath = p.join(Directory.current.path, 'encrypted.sqlite');
      print(dbPath);
      await File(dbPath).create();
    });

    tearDown(() async {
      // await dbFile.delete(recursive: true);
    });

    test('encrypts a real file and rejects access without the key', () async {
      if (!_supportsSqlCipher()) {
        print('No support sqlcipher');
        return; // Skip when the bundled sqlite3 is not built with SQLCipher.
      }

      final paserk = Licensify.generateEncryptionKey().toPaserk();

      final connection = await openFileDb(
        options: SqliteConnectionOptions(nativePath: dbPath),
        sqlCipherKey: SqlCipherKey.fromPaserk(paserk: paserk),
      );

      connection.database.execute(
        'CREATE TABLE secrets(id TEXT PRIMARY KEY, body TEXT);',
      );
      connection.database.execute(
        "INSERT INTO secrets(id, body) VALUES ('note-1', 'top secret');",
      );
      await connection.close();

      final unlocked = await openFileDb(
        options: SqliteConnectionOptions(nativePath: dbPath),
        sqlCipherKey: SqlCipherKey.fromPaserk(paserk: paserk),
      );
      final rows = unlocked.database.select(
        'SELECT body FROM secrets WHERE id = ?',
        ['note-1'],
      );
      expect(rows.single['body'], 'top secret');
      await unlocked.close();

      // Opening without a key should fail once the encrypted pages are read.
      final dbWithoutKey = sqlite.sqlite3.open(dbPath);
      expect(
        () => dbWithoutKey.select('SELECT count(*) FROM secrets;'),
        throwsA(
          isA<sqlite.SqliteException>().having(
            (error) => error.message.toLowerCase(),
            'message',
            contains('not a database'),
          ),
        ),
      );
      dbWithoutKey.dispose();
    });
  });
}

bool _supportsSqlCipher() {
  final database = sqlite.sqlite3.openInMemory();
  try {
    final result = database.select('PRAGMA cipher_version;');
    return result.isNotEmpty;
  } on sqlite.SqliteException {
    return false;
  } finally {
    database.dispose();
  }
}
