import 'dart:async';

import 'package:sqlite3/common.dart' as sqlite;

/// Lightweight wrapper around sqlite3 databases to match the previous API.
class DatabaseConnection {
  DatabaseConnection(this.database);

  final sqlite.CommonDatabase database;

  Future<void> close() => Future.sync(() => database.dispose());
}
