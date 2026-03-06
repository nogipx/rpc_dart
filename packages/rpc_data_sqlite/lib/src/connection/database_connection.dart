// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';

import 'package:sqlite3/common.dart' as sqlite;

/// Lightweight wrapper around sqlite3 databases to match the previous API.
class DatabaseConnection {
  DatabaseConnection(this.database, {Future<void> Function()? closeHook})
      : _closeHook = closeHook;

  final sqlite.CommonDatabase database;
  final Future<void> Function()? _closeHook;

  Future<void> close() async {
    database.close();
    if (_closeHook != null) await _closeHook();
  }
}
