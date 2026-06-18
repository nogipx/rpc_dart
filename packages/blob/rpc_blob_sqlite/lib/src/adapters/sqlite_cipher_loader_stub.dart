// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

/// SQLCipher is only supported on IO platforms with an appropriate sqlite3 build.
void configureSqlCipherDynamicLibrary({String? libraryPath}) {
  libraryPath;
  throw UnsupportedError(
    'SQLCipher is only supported on IO platforms with a compatible sqlite3 build.',
  );
}

bool get isSqlCipherAvailable => false;
