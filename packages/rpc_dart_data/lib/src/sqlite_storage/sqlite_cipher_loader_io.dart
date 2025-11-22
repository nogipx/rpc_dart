import 'dart:ffi';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sqlite3/open.dart' as sqlite_open;

/// Configures sqlite3 to load a SQLCipher-enabled library on supported
/// platforms (currently macOS and Linux) before any database is opened.
///
/// The resolver checks, in order:
/// 1) [libraryPath] if provided explicitly.
/// 2) `SQLITE3_LIB_DIR` + `SQLITE3_LIB_NAME` (or `sqlcipher` by default).
/// 3) Common Homebrew locations on macOS.
///
/// If no suitable library is found, the override is not installed.
void configureSqlCipherDynamicLibrary({String? libraryPath}) {
  final os = sqlite_open.open.os;
  if (os != sqlite_open.OperatingSystem.macOS &&
      os != sqlite_open.OperatingSystem.linux) {
    return;
  }

  final resolved = libraryPath ?? _fromEnv(os!) ?? _fromCommonLocations(os!);
  if (resolved == null) {
    return;
  }

  sqlite_open.open.overrideFor(
    os!,
    () => DynamicLibrary.open(resolved),
  );
}

String? _fromEnv(sqlite_open.OperatingSystem os) {
  final dir = Platform.environment['SQLITE3_LIB_DIR'];
  if (dir == null || dir.trim().isEmpty) {
    return null;
  }
  final name = (Platform.environment['SQLITE3_LIB_NAME'] ?? 'sqlcipher').trim();
  if (name.isEmpty) {
    return null;
  }
  final suffix = os == sqlite_open.OperatingSystem.macOS ? 'dylib' : 'so';
  final candidate = p.join(dir, 'lib$name.$suffix');
  return File(candidate).existsSync() ? candidate : null;
}

String? _fromCommonLocations(sqlite_open.OperatingSystem os) {
  if (os == sqlite_open.OperatingSystem.macOS) {
    const candidates = [
      '/opt/homebrew/opt/sqlcipher/lib/libsqlcipher.dylib',
      '/usr/local/opt/sqlcipher/lib/libsqlcipher.dylib',
    ];
    for (final path in candidates) {
      if (File(path).existsSync()) {
        return path;
      }
    }
  }
  return null;
}
