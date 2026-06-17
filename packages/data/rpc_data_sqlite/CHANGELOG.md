## 1.0.1

- Web (dart2js / Wasm) path correctness. Verified the injected-`CommonDatabase`
  adapter surface (`SqliteDataStorageAdapter.connection`) imports only
  `package:sqlite3/common.dart` (Wasm-compatible) and `package:sqlite3/wasm.dart`
  on the web path; `dart:io`, `dart:ffi` and `package:sqlite3/sqlite3.dart` (FFI)
  remain confined to the `if (dart.library.io)` loader/connection files and never
  leak onto the web import chain. The `.memory()`/`.file()` convenience factories
  go through the conditional loader whose web stub throws `UnsupportedError`
  (web apps inject their own `sqlite3mc`-on-Wasm db). Added a JS compile smoke
  test (`test/web_smoke_test.dart`, `dart test -p node`) proving the web-facing
  API compiles to JS clean. Full Wasm db execution still requires the app to
  supply `sqlite3mc.wasm`.

## 4.0.0

- Initial extraction from `rpc_data` with SQLite/SQLCipher adapter, schema registry, connection helpers for IO and WebAssembly.
