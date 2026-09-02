<!--
SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>

SPDX-License-Identifier: MIT
-->

## 0.3.0

### Changed

- Requires rpc_dart 5. See its changelog: flow control is on by default, an
  expired deadline is now `RpcDeadlineExceededException` on every shape, and a
  stream that ends without a trailer raises `UNAVAILABLE`.

## 0.2.3

**Startup robustness (IO isolates):**
- Fixed `RpcIsolateTransport.spawn` hanging forever (or returning a silently-dead transport) when the worker isolate crashed or exited before completing the handshake. The host previously did `await initPort.first` with no error/exit/timeout handling, and the `onError`/`onExit` ports only closed a still-null channel, so a worker that threw during startup left `spawn()` stuck. `spawn()` now:
  - races the worker SendPort handshake against the isolate's `onError`/`onExit` ports and surfaces the isolate's error message and stack trace as a thrown exception (instead of hanging);
  - waits for an explicit worker `ready` ack (sent after the user entrypoint runs without throwing), so a throwing/crashing entrypoint makes `spawn()` throw rather than return a dead transport;
  - enforces a configurable `startupTimeout` (default 30s); on timeout it kills the isolate, closes all ports, and throws a `TimeoutException` with context;
  - cleans up all ports and subscriptions on every exit path (success, error, timeout) via a `Completer` + try/finally pattern.
- The worker wrapper no longer silently swallows user-entrypoint startup exceptions; it rethrows them so the host observes the real cause via the `onError` port.
- Added `startupTimeout` parameter to `spawn` across all variants (IO, web, stub) for API parity.
- Regression test: `test/audit/spawn_handshake_failure_test.dart` (entrypoint throwing before handshake makes `spawn()` throw, not hang; plus a successful-spawn guard).

## 0.2.2

**Web (Web Worker) fixes:**
- Fixed a startup race that could silently drop the first RPC frames on web. `RpcIsolateTransport.spawn` previously returned on isolate_manager's `initialized()` ack, which fires before the worker `entrypoint` registers its responder; frames sent immediately were dropped (the bridge/channel streams are non-buffering `broadcast(sync:true)`). The worker now emits a `ready` ack after the entrypoint runs, and `spawn` waits for it (with a 5s fallback for older worker builds).
- Pinned `isolate_manager` to an exact version: the web transport imports its private `src/` (implementation_imports), so a minor bump can silently break compilation. Verified against `isolate_manager: 6.3.2`.
- Added a web compile-guard test (`test/web_smoke_test.dart`, runs on chrome) so a broken isolate_manager private-API import fails CI instead of only at runtime, and a REAL Web Worker end-to-end test (`test/web_worker/`, unary + server-stream over a separately-compiled worker) wired into CI.

## 0.2.1

- Expanded transport test suite (no library changes). Added typed end-to-end
  RPC contract coverage across the isolate boundary for all method kinds (unary,
  server-stream, client-stream, bidirectional), asserting payload correctness and
  ordering. New tests also cover: mid-stream server-stream cancellation tearing
  down without a hang, typed `RpcStatusException` propagation from a worker
  handler, concurrent calls/streams not crossing wires, high-volume ordered
  delivery, byte-for-byte large/edge-case binary (zero-copy) round-trips, and
  lifecycle guarantees (use-after-close fails cleanly, double-close/double-kill
  are safe, caller rejects calls after close).

## 0.2.0

- Updated to `rpc_dart: ^3.0.0`.
- Migrated to 3-layer transport architecture (`IRpcChannel` / `IRpcMultiplexedChannel` / `RpcChannelTransport`).

## 0.1.0

- Initial release: Isolate-based transport for rpc_dart (IO + web/wasm via `isolate_manager`).
