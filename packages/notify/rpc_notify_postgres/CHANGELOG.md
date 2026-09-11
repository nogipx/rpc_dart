<!--
SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>

SPDX-License-Identifier: MIT
-->

## 1.1.0

### Changed

- Requires rpc_notify 1.4.0, which releases per-topic distributors instead of
  retaining them for the life of the process, and no longer disposes a
  repository it was handed. Through it, rpc_dart 6 — see its changelog.

## 1.0.0

- Initial release: PostgreSQL `LISTEN`/`NOTIFY` backed repository for
  `rpc_notify`, with topic subscriptions delivered as change streams.
