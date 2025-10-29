import 'package:drift/drift.dart';

import '../drift_storage.dart';
import 'options.dart';

Never _unsupported() => throw UnsupportedError(
      'Drift connections are not supported on this platform.',
    );

Future<DatabaseConnection> openMainDb({
  DriftConnectionOptions options = DriftConnectionOptions.defaults,
  bool logStatements = false,
  SqlCipherKey? sqlCipherKey,
  SqliteSetupHook? sqliteSetup,
}) async =>
    _unsupported();

Future<DriftDataStorageAdapter> openMainStorage({
  DriftConnectionOptions options = DriftConnectionOptions.defaults,
  bool logStatements = false,
  SqlCipherKey? sqlCipherKey,
  SqliteSetupHook? sqliteSetup,
}) async =>
    _unsupported();

Future<void> replaceMainDbFromBytes(
  Uint8List bytes, {
  DriftConnectionOptions options = DriftConnectionOptions.defaults,
}) async =>
    _unsupported();

Future<DatabaseConnection> openTempDbFromBytes(
  Uint8List bytes, {
  DriftConnectionOptions options = DriftConnectionOptions.defaults,
  bool logStatements = false,
  SqliteSetupHook? sqliteSetup,
}) async =>
    _unsupported();

Future<DriftDataStorageAdapter> openTempStorageFromBytes(
  Uint8List bytes, {
  DriftConnectionOptions options = DriftConnectionOptions.defaults,
  bool logStatements = false,
  SqliteSetupHook? sqliteSetup,
}) async =>
    _unsupported();
