<!--
SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>

SPDX-License-Identifier: MIT
-->

# rpc_data_postgres

PostgreSQL adapter and repository for [`rpc_data`](../rpc_data). Stores collections as JSONB tables with optimistic concurrency, index management, and schema registry support.

```dart
import 'package:postgres/postgres.dart';
import 'package:rpc_data_postgres/rpc_data_postgres.dart';

Future<void> main() async {
  final adapter = await PostgresDataStorageAdapter.connect(
    endpoint: Endpoint(host: 'localhost', database: 'app', username: 'app'),
  );
  final repo = PostgresDataRepository(storage: adapter);
  // ...
  await repo.dispose();
}
```
