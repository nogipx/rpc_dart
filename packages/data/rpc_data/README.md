<!--
SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>

SPDX-License-Identifier: MIT
-->

# rpc_data

Driver-agnostic data layer (CRUD, queries, change streams) for [`rpc_dart`](https://pub.dev/packages/rpc_dart). Core package stays free of IO/FFI so it works in WASM and other constrained targets; database drivers live in companion packages.

## Packages in this repo
- `rpc_data` – core contracts, in-memory repository, schema validation, RPC helpers.
- `rpc_data_sqlite` – SQLite/SQLCipher adapter + repository + cross-platform connection helpers (IO, WebAssembly).
- `rpc_data_postgres` – PostgreSQL adapter + repository.

## Quick start (in-memory)
```dart
import 'package:rpc_data/rpc_data.dart';

Future<void> main() async {
  final env = await DataServiceFactory.inMemory();
  final client = env.client;

  final created = await client.create(
    collection: 'notes',
    payload: {'title': 'Hello', 'done': false},
  );
  print('created: ${created.id} v=${created.version}');

  final listed = await client.list(
    collection: 'notes',
    options: const QueryOptions(limit: 5),
  );
  for (final record in listed.records) {
    print('note ${record.id}: ${record.payload}');
  }

  await env.dispose();
}
```

## Choosing a driver
- Add `rpc_data_sqlite` for local-first / SQLCipher / web OPFS builds. The package re-exports `rpc_data`.
- Add `rpc_data_postgres` for server-side JSONB-backed storage.
- Keep `rpc_data` alone for pure in-memory or to build your own adapter.
