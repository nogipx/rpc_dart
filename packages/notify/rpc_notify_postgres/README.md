<!--
SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>

SPDX-License-Identifier: MIT
-->

# rpc_notify_postgres

PostgreSQL LISTEN/NOTIFY backed `INotifyRepository` for
[`rpc_notify`](../rpc_notify). Fans topic events out across server replicas via
`NOTIFY`, so a subscriber connected to one instance receives events published by
any other.

Like the in-memory backend, this is a **stateless relay**: nothing is persisted
(no tables, no schema), and a subscriber only receives events published while it
is subscribed. There is no backlog, replay, cursor, or acknowledgement.

## Quick start

```dart
import 'package:postgres/postgres.dart';
import 'package:rpc_notify/rpc_notify.dart';
import 'package:rpc_notify_postgres/rpc_notify_postgres.dart';

Future<void> main() async {
  final repo = await PostgresNotifyRepository.connect(
    endpoint: Endpoint(
      host: 'localhost',
      database: 'app',
      username: 'app',
      password: 'app',
    ),
    settings: const ConnectionSettings(sslMode: SslMode.disable),
  );

  // Inject into the notify server on every replica.
  final server = NotifyServiceFactory.createServer(
    transport: transport, // any IRpcTransport
    repository: repo,
  );

  // Or drive the repository directly.
  repo.subscribe('client-1', 'orders').listen((e) => print(e.payload));
  repo.publish('orders', {'id': '42'});
  repo.publishTo('client-1', 'orders', {'private': true});

  await repo.dispose();
}
```

## Configuration

`PostgresNotifyRepository.connect` options:

- `endpoint` — `postgres` package `Endpoint` (host/port/database/credentials).
- `settings` — optional `ConnectionSettings` (SSL mode, timeouts, etc.).
- `healthCheckInterval` — how often the connection is checked for liveness
  (default 10s).

Each topic maps directly to a PostgreSQL channel. On connection loss the
repository reconnects with backoff and re-issues `LISTEN` for all active topics.

## Testing

The tests require a running PostgreSQL on `localhost:5433`
(`postgres`/`postgres`). Being service-dependent, this package is excluded from
`melos run test:unit` (matched by `*_postgres`); run it with a live database:

```sh
docker run -d --rm --name pg -p 5433:5432 \
  -e POSTGRES_PASSWORD=postgres postgres:16-alpine
fvm dart test
```
