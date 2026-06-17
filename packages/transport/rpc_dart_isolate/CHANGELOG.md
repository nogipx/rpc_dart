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
