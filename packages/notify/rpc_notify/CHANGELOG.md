<!--
SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>

SPDX-License-Identifier: MIT
-->

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
