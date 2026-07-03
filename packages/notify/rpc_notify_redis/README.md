<!--
SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>

SPDX-License-Identifier: MIT
-->

# rpc_notify_redis

Redis Pub/Sub backed `INotifyRepository` for [`rpc_notify`](../rpc_notify).
Fans topic events out across server replicas via `PUBLISH`/`SUBSCRIBE`, so a
subscriber connected to one instance receives events published by any other.

Like the Postgres backend, this is a **stateless relay**: nothing is persisted,
and a subscriber only receives events published while it is subscribed. There
is no backlog, replay, cursor, or acknowledgement. For Redis this maps to
Pub/Sub, not Streams.

## Quick start

```dart
import 'package:rpc_notify/rpc_notify.dart';
import 'package:rpc_notify_redis/rpc_notify_redis.dart';

Future<void> main() async {
  final repo = await RedisNotifyRepository.connect(
    host: 'localhost',
    port: 6379,
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

`RedisNotifyRepository.connect` options:

- `host` / `port` — Redis endpoint (default `localhost:6379`).
- `username` / `password` — optional `AUTH` (username for ACL users).
- `useTls` — connect over TLS (`connectSecure`).
- `keyPrefix` — channel namespace, prepended to every topic
  (default `rpc_notify:`). Replicas must share the same prefix to see each
  other's events.
- `healthCheckInterval` — periodic `PING` used to detect a dead connection
  (default 10s).

There is no `db` option: Redis Pub/Sub is server-global and ignores the selected
database. Isolate namespaces with `keyPrefix` instead.

## Behavior

- Two Redis connections are opened: one dedicated to `SUBSCRIBE` (a connection
  in subscribe mode cannot issue other commands) and one for `PUBLISH`.
- `publish` / `publishTo` are fire-and-forget (`void`); they no-op silently
  while the connection is down.
- `publishTo` tags the event with the target `clientId` so only the replica
  holding that client delivers it.
- On connection loss the repository reconnects with backoff and re-subscribes
  to all active topics.

## Testing

The tests require a running Redis. Start one and run them:

```sh
docker run -d --rm --name redis -p 6379:6379 redis:7-alpine
fvm dart test
```

Being service-dependent, this package is excluded from `melos run test:unit`
(matched by `*_redis`).
