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
      throw const FormatException('Empty PASERK SQLCipher key.');
    }

    try {
      final symmetricKey = LicensifySymmetricKey.fromPaserk(paserk: trimmed);
      return symmetricKey.executeWithKeyBytes((keyBytes) {
        return SqlCipherKey.fromBytes(keyBytes: Uint8List.fromList(keyBytes));
      });
    } on FormatException catch (error) {
      throw FormatException('Invalid PASERK SQLCipher key: ${error.message}');
    } catch (error) {
      throw FormatException('Failed to read PASERK SQLCipher key: $error');
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
      // SQLite3MultipleCiphers: choose SQLCipher-compatible codec and legacy
      // page format before applying the key so existing SQLCipher databases
      // remain compatible.
      database.execute("PRAGMA cipher = 'sqlcipher';");
      database.execute('PRAGMA legacy = 4;');

      _assertCipherAvailable(database);

      final hexKey = _encodeHex(_keyBytes);
      database.execute("PRAGMA key = \"x'$hexKey'\";");

      _assertCipherAvailable(database);

      if (enforceMemorySecurity) {
        database.execute('PRAGMA cipher_memory_security = ON;');
      }
    } on sqlite.SqliteException catch (error) {
      throw SqlCipherException(
        'Failed to apply SQLCipher settings: ${error.message}',
        cause: error,
      );
    } finally {
      _zeroBytes(_keyBytes);
      _consumed = true;
    }
  }

  static void _assertCipherAvailable(sqlite.CommonDatabase database) {
    try {
      final result = database.select('PRAGMA cipher_version;');
      final version = result.isNotEmpty ? result.single.values.first : null;
      final hasVersion =
          version != null && version.toString().trim().isNotEmpty;
      if (!hasVersion) {
        final cipherRows = database.select('PRAGMA cipher;');
        final hasSqlcipherCipher = cipherRows.any(
          (row) => row.values.any((value) => '$value' == 'sqlcipher'),
        );
        if (!hasSqlcipherCipher) {
          throw SqlCipherException(
            'SQLCipher not active: cipher_version empty and provider not set.',
          );
        }
      }
    } on sqlite.SqliteException catch (error) {
      throw SqlCipherException(
        'SQLite build does not expose SQLCipher (cipher_version unavailable).',
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
