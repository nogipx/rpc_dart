// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'package:sqlite3/common.dart' as sqlite_common;

sqlite_common.CommonDatabase openInMemory() {
  throw UnsupportedError(
    'Opening SQLite databases directly is only supported on IO platforms.',
  );
}

sqlite_common.CommonDatabase openFile(String path) {
  path;
  throw UnsupportedError(
    'Opening SQLite databases directly is only supported on IO platforms.',
  );
}
