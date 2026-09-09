# Checked — do not re-run

What a negative is, how it differs from a lead, and why detector sweeps do not
live here — [../LOOP.md](../LOOP.md).

- **[C-01](C-01-sustained-load.md)** round 191, websocket, http2, isolate — ordinary sustained load retains nothing
- **[C-02](C-02-frame-codec-hostile-frames.md)** round 46, core and websocket — the frame codec against nine hostile frames
- **[C-03](C-03-ping-flood.md)** round 77, http2 — a PING flood is not a defect, the per-unit figure falls
- **[C-04](C-04-peer-chosen-stream-ids.md)** round 106, every transport — peer-chosen stream ids
- **[C-05](C-05-inbound-security-parity.md)** round 103, http2 — the responder validates inbound metadata
- **[C-06](C-06-lifecycle-apis-twice.md)** round 77, transports and the http2 server — a sweep of the lifecycle APIs
- **[C-07](C-07-outbound-backpressure-websocket.md)** rounds 60-61, websocket and core — outbound backpressure is bounded by the credit window
- **[C-08](C-08-cancel-reaches-handler-websocket.md)** round 137, websocket — cancellation reaches the handler
- **[C-09](C-09-half-close-racing-trailers.md)** round 125, websocket — half-close racing the trailers, 360/360
- **[C-10](C-10-ghost-stream-ids-from-peer.md)** round 123, websocket — ghost stream ids from a hostile server
- **[C-11](C-11-reconnect-with-open-streams.md)** round 123, websocket — `reconnect()` with open streams, and id reuse
- **[C-12](C-12-wasm-byte-pipe.md)** round 184, wasm — the byte pipe on both platforms
- **[C-13](C-13-wasm-load-close-cycles.md)** round 185, wasm — 40 load/close cycles
- **[C-14](C-14-wasm-real-guest-batteries.md)** round 187, wasm — three batteries against a real guest
- **[C-15](C-15-grpc-listener-and-cancellation.md)** rounds 54 and 55, http2 — listener resilience and cancellation from a real gRPC client
- **[C-16](C-16-http2-caller-inbound-buffers.md)** round 52, http2 — the caller's inbound buffers
- **[C-17](C-17-message-level-gzip.md)** core — message-level gzip is bounded
- **[C-18](C-18-leak-audit-coverage.md)** the whole repository — the full leak audit, one defect, everything else clean
- **[C-19](C-19-http2-refuses-a-slow-consumer.md)** rounds 213-214, http2 — a consumer that falls behind is failed, by design and by owner decision
- **[C-20](C-20-pre-method-budget-held-for-the-reclaim.md)** round 215, core — the pre-method budget is held until the reclaim, on purpose; looks like a leak, is not
- **[C-21](C-21-header-cap-has-a-floor.md)** round 216, core and http2 — `maxHeaderValueBytes` has a floor; below ~40 the server refuses its own headers and confounds any bench

Large payloads with fragmentation (round 64) and server-side keepalive
(round 63) live in `../backlog/B-06-websocket-lead-list-is-stale.md`: there they
also carry the conclusion about the stale lead list.
