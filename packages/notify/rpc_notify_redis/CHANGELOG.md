<!--
SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>

SPDX-License-Identifier: MIT
-->

## 1.1.0

### Fixed

- The reconnect latch can no longer be stranded, which left the client unable
  to reconnect for the rest of its life.

## 1.0.0

- Initial release: Redis Pub/Sub backed repository for `rpc_notify`, with topic
  subscriptions delivered as change streams.
