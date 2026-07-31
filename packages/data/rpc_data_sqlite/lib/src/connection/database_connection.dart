// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';

import 'package:sqlite3/common.dart' as sqlite;

/// Lightweight wrapper around sqlite3 databases to match the previous API.
class DatabaseConnection {
  DatabaseConnection(
    this.database, {
    Future<void> Function()? closeHook,
    Future<void> Function()? flushHook,
  }) : _closeHook = closeHook,
       _flushHook = flushHook;

  final sqlite.CommonDatabase database;
  final Future<void> Function()? _closeHook;
  final Future<void> Function()? _flushHook;

  /// Waits until everything written so far has actually reached durable
  /// storage, and completes immediately where it already had.
  ///
  /// Only the web IndexedDB VFS needs this. sqlite3's VFS interface is
  /// synchronous and IndexedDB is not, so that VFS acknowledges a write and
  /// performs it afterwards, from a queue — meaning a tab or app killed
  /// between the two loses writes the database already reported as committed.
  /// The native VFS writes through to the file and has nothing to wait for, so
  /// this is a no-op there.
  ///
  /// Call it where losing the last writes would actually cost something: after
  /// a unit of work completes, and before the host is suspended
  /// (`visibilitychange`, `pagehide`). It waits for work queued BEFORE the
  /// call, so calling it per-write inside a loop only serialises the queue —
  /// no extra IO, but no benefit either.
  Future<void> flush() async {
    if (_flushHook != null) await _flushHook();
  }

  Future<void> close() async {
    database.close();
    if (_closeHook != null) await _closeHook();
  }
}
