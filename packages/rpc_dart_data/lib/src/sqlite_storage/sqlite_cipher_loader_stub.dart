// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

/// No-op stub for platforms without FFI (e.g., web).
void configureSqlCipherDynamicLibrary({String? libraryPath}) {
  libraryPath;
}

bool get isSqlCipherAvailable => false;
