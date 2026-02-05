// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:typed_data';

import 'package:licensify/licensify.dart';
import 'package:sqlite3/common.dart' as sqlite;

/// SQLCipher-specific exception wrapper with optional underlying cause.
class SqlCipherException implements Exception {
  SqlCipherException(this.message, {this.cause});

  final String message;
  final Object? cause;

  @override
  String toString() {
    if (cause == null) {
      return 'SqlCipherException: $message';
    }
    return 'SqlCipherException: $message (cause: $cause)';
  }
}

/// Container for SQLCipher key material imported from a PASERK string.
///
/// The key is converted to a hexadecimal string and injected through
/// `PRAGMA key`. The key material is zeroed out after single use.
class SqlCipherKey {
  SqlCipherKey._(this._keyBytes);

  factory SqlCipherKey.fromBytes({required Uint8List keyBytes}) {
    if (keyBytes.isEmpty) {
      throw const FormatException('SQLCipher key must not be empty.');
    }
    return SqlCipherKey._(Uint8List.fromList(keyBytes));
  }

  factory SqlCipherKey.fromPaserk({required String paserk}) {
    final trimmed = paserk.trim();
    if (trimmed.isEmpty) {
      throw const FormatException('Пустой PASERK ключ SQLCipher.');
    }

    try {
      final symmetricKey = LicensifySymmetricKey.fromPaserk(paserk: trimmed);
      return symmetricKey.executeWithKeyBytes((keyBytes) {
        return SqlCipherKey.fromBytes(keyBytes: Uint8List.fromList(keyBytes));
      });
    } on FormatException catch (error) {
      throw FormatException(
        'Некорректный PASERK ключ SQLCipher: ${error.message}',
      );
    } catch (error) {
      throw FormatException(
        'Не удалось прочитать PASERK ключ SQLCipher: $error',
      );
    }
  }

  final Uint8List _keyBytes;
  bool _consumed = false;

  void applyTo(
    sqlite.CommonDatabase database, {
    bool enforceMemorySecurity = true,
  }) {
    if (_consumed) {
      throw StateError('SQLCipher key material has already been consumed.');
    }

    try {
      // SQLite3MultipleCiphers: try to select SQLCipher-compatible provider
      // first. Some builds may ship without the `sqlcipher` provider (for
      // example when the WASM bundle was built without that flag). In that
      // case fall back to the first available cipher instead of failing hard
      // so encrypted databases still work.
      final selectedCipher = _selectCipherProvider(database);
      if (selectedCipher == _sqlcipherProvider) {
        database.execute('PRAGMA legacy = 4;');
      }

      // Fail fast: if the binary does not expose cipher pragmas, do not
      // continue with an unencrypted database.
      _assertCipherAvailable(database, expectedProvider: selectedCipher);

      final hexKey = _encodeHex(_keyBytes);
      database.execute("PRAGMA key = \"x'$hexKey'\";");

      _assertCipherAvailable(database, expectedProvider: selectedCipher);

      if (enforceMemorySecurity) {
        try {
          database.execute('PRAGMA cipher_memory_security = ON;');
        } catch (_) {
          // Older or trimmed-down builds may not support this pragma; ignore.
        }
      }
    } on sqlite.SqliteException catch (error) {
      throw SqlCipherException(
        'Ошибка применения настроек SQLCipher: ${error.message}',
        cause: error,
      );
    } finally {
      _zeroBytes(_keyBytes);
      _consumed = true;
    }
  }

  static const _sqlcipherProvider = 'sqlcipher';

  static String _selectCipherProvider(sqlite.CommonDatabase database) {
    // First, try to select the preferred SQLCipher provider.
    try {
      database.execute("PRAGMA cipher = '$_sqlcipherProvider';");
      return _sqlcipherProvider;
    } on sqlite.SqliteException catch (error) {
      // If that fails, try to discover any available provider.
      final providers = _availableProviders(database);
      if (providers.isNotEmpty) {
        final fallback = providers.first;
        database.execute("PRAGMA cipher = '$fallback';");
        return fallback;
      }

      // As a last resort, inspect current cipher pragma (some builds expose
      // it even when cipher_list is missing) and keep using whatever is
      // reported there.
      try {
        final rows = database.select('PRAGMA cipher;');
        final reported = rows
            .map((row) => row.values)
            .expand((v) => v)
            .map((v) => '$v'.trim())
            .firstWhere(
              (v) => v.isNotEmpty,
              orElse: () => '',
            );
        if (reported.isNotEmpty) {
          database.execute("PRAGMA cipher = '$reported';");
          return reported;
        }
      } catch (_) {
        // ignore, will throw below
      }

      throw SqlCipherException(
        'Сборка SQLite не поддерживает шифрование (cipher_list пустой, cipher=\'sqlcipher\' недоступен).',
        cause: error,
      );
    }
  }

  static List<String> _availableProviders(sqlite.CommonDatabase database) {
    try {
      final rows = database.select('PRAGMA cipher_list;');
      return rows
          .map((row) => row.values)
          .expand((v) => v)
          .map((v) => '$v'.trim())
          .where((v) => v.isNotEmpty)
          .toList();
    } catch (_) {
      // Some builds omit cipher_list; return empty so callers can fallback.
      return const [];
    }
  }

  static void _assertCipherAvailable(
    sqlite.CommonDatabase database, {
    String? expectedProvider,
  }) {
    try {
      final result = database.select('PRAGMA cipher_version;');
      final version = result.isNotEmpty ? result.single.values.first : null;
      final hasVersion =
          version != null && version.toString().trim().isNotEmpty;
      if (!hasVersion) {
        final cipherRows = database.select('PRAGMA cipher;');
        final providers = cipherRows
            .map((row) => row.values)
            .expand((v) => v)
            .map((v) => '$v')
            .toList();
        final hasExpected = expectedProvider == null
            ? providers.isNotEmpty
            : providers.any(
                (provider) => provider.toString().trim() == expectedProvider,
              );
        if (!hasExpected) {
          throw SqlCipherException(
            'SQLCipher не активирован: cipher_version пустой и провайдер не выставлен.',
          );
        }
      }
    } on sqlite.SqliteException catch (error) {
      throw SqlCipherException(
        'Сборка SQLite не поддерживает SQLCipher (cipher_version недоступен).',
        cause: error,
      );
    }
  }

  static String _encodeHex(Uint8List bytes) {
    final buffer = StringBuffer();
    for (final byte in bytes) {
      buffer.write(byte.toRadixString(16).padLeft(2, '0'));
    }
    return buffer.toString();
  }

  static void _zeroBytes(Uint8List bytes) {
    for (var i = 0; i < bytes.length; i += 1) {
      bytes[i] = 0;
    }
  }
}
