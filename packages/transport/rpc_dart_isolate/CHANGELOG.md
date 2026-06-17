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
