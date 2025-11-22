import 'dart:io';
import 'dart:typed_data';

import 'package:licensify/licensify.dart';
import 'package:path/path.dart' as p;
import 'package:rpc_dart_data/src/connection/connection_native.dart';
import 'package:rpc_dart_data/src/connection/options.dart';
import 'package:rpc_dart_data/src/sqlite_storage/sql_cipher.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;
import 'package:test/test.dart';

void main() {
  group('SQLCipher file I/O', () {
    late String dbPath;
    final keyBytes = Uint8List.fromList(List.generate(32, (i) => i));

    setUp(() async {
      dbPath = p.join(Directory.current.path, 'encrypted.sqlite');
      await File(dbPath).parent.create(recursive: true);
    });

    test('encrypts a real file and rejects access without the key', () async {
      final paserk =
          LicensifySymmetricKey.xchacha20(keyBytes: keyBytes).toPaserk();

      final connection = await openFileDb(
        options: SqliteConnectionOptions(nativePath: dbPath),
        sqlCipherKey: SqlCipherKey.fromPaserk(paserk: paserk),
      );

      connection.database.execute(
        'CREATE TABLE IF NOT EXISTS secrets(id TEXT PRIMARY KEY, body TEXT);',
      );
      connection.database.execute(
        "INSERT OR REPLACE INTO secrets(id, body) VALUES ('note-1', 'top secret');",
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
