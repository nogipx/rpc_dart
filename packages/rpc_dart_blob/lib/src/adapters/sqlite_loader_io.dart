import 'dart:math';

import 'package:sqlite3/common.dart' as sqlite_common;
import 'package:sqlite3/sqlite3.dart' as sqlite_ffi;

sqlite_common.CommonDatabase openInMemory() {
  // Use a unique in-memory database name to avoid shared-cache reuse.
  final seed =
      DateTime.now().microsecondsSinceEpoch ^ Random().nextInt(1 << 32);
  final name = 'file:rpc_blob_mem_$seed?mode=memory&cache=shared';
  return sqlite_ffi.sqlite3.open(name, uri: true);
}

sqlite_common.CommonDatabase openFile(String path) {
  return sqlite_ffi.sqlite3.open(path);
}
