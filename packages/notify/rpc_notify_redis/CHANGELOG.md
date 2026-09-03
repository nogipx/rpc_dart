<!--
SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>

SPDX-License-Identifier: MIT
-->

## 1.2.0

### Fixed

- Requires rpc_notify 1.3.0, where a per-connection subscriber no longer
  disposes the shared repository. That is what left a replica holding no Redis
  connection at all after its first client disconnected.
- Every network wait is bounded: the connect, the AUTH, the close and the
  health PING. A hung call stranded the reconnect latch, which gates both the
  reconnect and the health check, so the repository stopped trying.
- A publish that reaches nobody is reported (one line per 30s) and triggers a
  reconnect, instead of returning at a null check.

### Added

- A heartbeat line with the connection state, because the failure this guards
  against produces no events at all — an idle connection can die with the
  subscriber stream signalling neither done nor error.
- `dispose()` is idempotent and says that the bus is closing. Subscribing to a
  disposed repository throws instead of returning a subscription that looks
  healthy and never delivers.

## 1.1.0

### Fixed

- The reconnect latch can no longer be stranded, which left the client unable
  to reconnect for the rest of its life.

## 1.0.0

- Initial release: Redis Pub/Sub backed repository for `rpc_notify`, with topic
  subscriptions delivered as change streams.
