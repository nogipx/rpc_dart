<!--
SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>

SPDX-License-Identifier: MIT
-->

## 1.3.0

### Fixed

- `INotifySubscriber.repository` no longer disposes the repository it was
  handed. A server builds its contracts per connection while the repository is
  shared by all of them, and rpc_dart disposes a connection's contracts when
  its endpoint closes — so together with rpc_dart_websocket 0.3.0, which
  started closing those endpoints, the first client disconnect ended notify
  for the whole process: no subscriptions, no reconnect, no log line. Pass
  `ownsRepository: true` for the old behaviour.
- A resubscribe after the repository closed a stream now gets a live one. The
  per-topic stream cache handed back the closed stream, and a listener on a
  closed broadcast stream is done at once, so a client retrying after a close
  never reattached.

### Changed

- `NotifyServiceFactory.createServer` disposes only a repository it created
  itself. One passed in belongs to the caller and outlives the server.

## 1.2.0

### Fixed

- Per-topic distributors are released when their last subscriber goes,
  instead of being retained for the life of the process.

### Changed

- Requires rpc_dart 5. See its changelog: flow control is on by default, an
  expired deadline is now `RpcDeadlineExceededException` on every shape, and a
  stream that ends without a trailer raises `UNAVAILABLE`.

## 1.1.0

- Adopted RpcTransportRouter and StreamDistributor (moved from rpc_dart core; kept internal, imported with hide because rpc_notify still pins rpc_dart 3.3.0 which also exports them).
