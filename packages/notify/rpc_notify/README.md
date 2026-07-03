<!--
SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>

SPDX-License-Identifier: MIT
-->

# rpc_notify

Topic-based async push notifications built on
[`rpc_dart`](../../core/rpc_dart). A server publishes events to named topics;
clients subscribe and receive a `Stream<NotifyEvent>` over any `IRpcTransport`
(WebSocket, HTTP/2, isolate, in-memory).

Delivery is **fire-and-forget**: events are pushed live to currently-connected
subscribers only. There is no persistence, backlog, replay, cursor, or
acknowledgement — a subscriber receives only events published while it is
subscribed.

## Quick start

### In-memory (tests / single process)

```dart
import 'package:rpc_notify/rpc_notify.dart';

Future<void> main() async {
  final env = await NotifyServiceFactory.inMemory();

  env.subscriber.subscribe('orders').listen((e) => print(e.payload));
  env.publisher.publish('orders', {'id': '42'});

  await env.dispose();
}
```

### Server

```dart
final server = NotifyServiceFactory.createServer(
  transport: transport, // any IRpcTransport
  // repository: await RedisNotifyRepository.connect(...), // optional backend
);
await server.start();
```

### Client

```dart
final subscriber = NotifyServiceFactory.createSubscriber(transport: transport);
final publisher = NotifyServiceFactory.createPublisher(transport: transport);

final sub = subscriber.subscribe('orders').listen((e) => print(e.payload));
publisher.publish('orders', {'id': '42'});

await subscriber.unsubscribe('orders');
await subscriber.dispose();
await publisher.close();
```

## Concepts

- **Topic** — a plain `String` channel. Events are isolated per topic.
- **`publish(topic, payload)`** — broadcast to every subscriber of the topic.
- **`publishTo(clientId, topic, payload)`** — deliver to a single client only.
- **`NotifyEvent`** — `{ topic, payload, timestamp, eventId? }`; `payload` is a
  JSON-serializable `Map<String, dynamic>`.
- **Direct vs RPC** — inside a server process use
  `INotifyPublisher.repository(repo)` / `INotifySubscriber.repository(repo)` for
  a zero-round-trip path; remote processes use the `.endpoint(...)` variants
  (what the factory wires up). `DirectNotifyServiceEnvironment` bundles both
  around an in-memory repository with no transport or serialization at all.

## Backends

The server routes events through an `INotifyRepository`. The default is
`InMemoryNotifyRepository` (single process). For fan-out across replicas, inject
a shared backend:

- [`rpc_notify_postgres`](../rpc_notify_postgres) — PostgreSQL LISTEN/NOTIFY.
- [`rpc_notify_redis`](../rpc_notify_redis) — Redis Pub/Sub.

Both are stateless relays with the same semantics as the in-memory backend, just
delivered across processes.

## Custom backend

Implement `INotifyRepository` (7 methods: `publish`, `publishTo`, `subscribe`,
`unsubscribe`, `activeTopics`, `subscriberCount`, `dispose`) and pass it to
`NotifyServiceFactory.createServer(repository: ...)`.
