import 'dart:async';

import 'package:sqlite3/sqlite3.dart' as sqlite;

/// Lightweight wrapper around sqlite3 databases to match the previous API.
class DatabaseConnection {
  DatabaseConnection(this.database);

  final sqlite.Database database;

  Future<void> close() => Future.sync(() => database.dispose());
}
