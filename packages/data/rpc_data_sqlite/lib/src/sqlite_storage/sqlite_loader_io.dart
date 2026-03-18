// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'package:sqlite3/common.dart' as sqlite_common;
import 'package:sqlite3/sqlite3.dart' as sqlite_ffi;

sqlite_common.CommonDatabase openInMemory() {
  return sqlite_ffi.sqlite3.openInMemory();
}

sqlite_common.CommonDatabase openFile(String path) {
  return sqlite_ffi.sqlite3.open(path);
}
