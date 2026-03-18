# rpc_data_sqlite

SQLite/SQLCipher adapter and repository for [`rpc_data`](../rpc_data). Includes cross-platform connection helpers (IO + WebAssembly), change journal, schema registry, FTS/index helpers, and SQLCipher loader hooks.

```dart
import 'package:rpc_data_sqlite/rpc_data_sqlite.dart';

Future<void> main() async {
  final connection = await openFileDb(
    options: const SqliteConnectionOptions(nativeFileName: 'app.sqlite'),
  );
  final storage = SqliteDataStorageAdapter.connection(connection);
  await storage.ensureReady();

  final repo = SqliteDataRepository(storage: storage);
  final env = await DataServiceFactory.inMemory(repository: repo);
  // ...
  await env.dispose();
  await connection.close();
}
```
