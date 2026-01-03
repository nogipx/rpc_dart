// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:rpc_dart_data/src/connection/connection_native.dart';
import 'package:rpc_dart_data/src/connection/options.dart';
import 'package:test/test.dart';

void main() {
  group('Native SQLite connections', () {
    test(
      'openInMemoryDb provides an open database and closes cleanly',
      () async {
        final connection = await openInMemoryDb();
        final result = connection.database.select('SELECT 1 as value;');
        expect(result.single['value'], 1);

        await connection.close();
        expect(() => connection.database.select('SELECT 1;'), throwsStateError);
      },
    );

    test(
      'openFileDb creates the target file when a path is provided',
      () async {
        final tempDir = await Directory.systemTemp.createTemp(
          'rpc-connection-test',
        );
        try {
          final dbFile = p.join(tempDir.path, 'connections.sqlite');
          final connection = await openFileDb(
            options: SqliteConnectionOptions(nativePath: dbFile),
          );

          try {
            connection.database.select('SELECT 1 as value;');
          } finally {
            await connection.close();
          }

          final file = File(dbFile);
          expect(await file.exists(), isTrue);
        } finally {
          await tempDir.delete(recursive: true);
        }
      },
    );
  });
}
