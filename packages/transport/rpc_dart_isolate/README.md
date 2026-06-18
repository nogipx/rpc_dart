<!--
SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>

SPDX-License-Identifier: MIT
-->

# rpc_dart_isolate

Isolate-based caller/responder transports for `rpc_dart`.

- VM: spawns isolates and bridges them with stream-ID multiplexing.
- Web/wasm: uses `isolate_manager` workers for parity API.
- API: `RpcIsolateTransport.spawn` returns `{ transport, kill }` pair.

Extracted from `rpc_dart_transports` to keep web-safe, single-responsibility package.
