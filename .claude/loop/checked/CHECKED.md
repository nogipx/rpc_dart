# Checked — do not re-run

What a negative is, how it differs from a lead, and why detector sweeps do not
live here — [../LOOP.md](../LOOP.md).

**`(stale, sha)` does not retract anything.** It means code under that record's
paths has changed since it was measured, so the claim is unverified rather than
wrong. A negative is never deleted; re-measuring one is a round's target, and
`loop.py stale` says when it is due. Marked in the curate pass after round 220,
where 20 of 50 records had aged — almost all of them because rounds 206-220
rewrote `channel_transport.dart` and the three http2 transports.

- **[C-27](C-27-keep-calling-on-one-connection.md)** pre-201, off-journal, websocket, isolate, http/1.1 — "keep calling on ONE connection" (60 sequential, 10 concurrent, 10 server-streams) is clean on the other three transports, and structurally so: none of them writes on the release path. Imported after round 234
- **[C-30](C-30-closed-transport-leniency-is-a-contract.md)** off-journal (60a57ead), core and isolate — a closed `RpcChannelTransport` is lenient ON PURPOSE, pinned by three tests; a fix attempt that made it throw failed all three and was backed out. Plus why the error must be delivered on a TIMER, not a microtask
- **[C-29](C-29-the-real-scope-of-the-stream-limits.md)** rounds 137, 139 off-journal, core and http2 — responder endpoints are PER CONNECTION (so never call this "the server going offline") **except on `RpcHttpServer`, which has one for the whole process** (round 271); the cost that crosses connections is ~33 KiB per parked stream, i.e. ~136 MB per connection at the default; `halfOpenStreamTimeout` covers DISPATCH ONLY; the peer-keyed bookkeeping audit is complete. Imported after round 235
- **[C-28](C-28-sibling-batteries-that-came-back-clean.md)** rounds 40, 99, 106, 109 off-journal, http, wasm, websocket, http2 — the clean rows of the sibling battery: the CORS/CSRF gate (415/415/405 with the handler never running), the responder side of peer loss, wasm clean by construction, and three asymmetries that are NOT defects. Imported after round 234
- **[C-01](C-01-sustained-load.md)** round 191, websocket, http2, isolate *(stale, 5bf4d34e)* — ordinary sustained load retains nothing
- **[C-02](C-02-frame-codec-hostile-frames.md)** round 46, core and websocket *(stale, 5bf4d34e)* — the frame codec against nine hostile frames
- **[C-03](C-03-ping-flood.md)** round 77, http2 *(stale, 5bf4d34e)* — a PING flood is not a defect, the per-unit figure falls
- **[C-04](C-04-peer-chosen-stream-ids.md)** round 106, every transport *(stale, 5bf4d34e)* — peer-chosen stream ids
- **[C-05](C-05-inbound-security-parity.md)** round 103, http2 *(stale, 5bf4d34e)* — the responder validates inbound metadata
- **[C-06](C-06-lifecycle-apis-twice.md)** round 77, transports and the http2 server *(stale, 5bf4d34e)* — a sweep of the lifecycle APIs
- **[C-07](C-07-outbound-backpressure-websocket.md)** rounds 60-61, websocket and core *(stale, 5bf4d34e)* — outbound backpressure is bounded by the credit window
- **[C-08](C-08-cancel-reaches-handler-websocket.md)** round 137, websocket — cancellation reaches the handler
- **[C-09](C-09-half-close-racing-trailers.md)** round 125, websocket — half-close racing the trailers, 360/360
- **[C-10](C-10-ghost-stream-ids-from-peer.md)** round 123, websocket — ghost stream ids from a hostile server
- **[C-11](C-11-reconnect-with-open-streams.md)** round 123, websocket — `reconnect()` with open streams, and id reuse
- **[C-12](C-12-wasm-byte-pipe.md)** round 184, wasm — the byte pipe on both platforms
- **[C-13](C-13-wasm-load-close-cycles.md)** round 185, wasm — 40 load/close cycles
- **[C-14](C-14-wasm-real-guest-batteries.md)** round 187, wasm — three batteries against a real guest
- **[C-15](C-15-grpc-listener-and-cancellation.md)** rounds 54 and 55, http2 *(stale, 5bf4d34e)* — listener resilience and cancellation from a real gRPC client
- **[C-16](C-16-http2-caller-inbound-buffers.md)** round 52, http2 *(stale, 5bf4d34e)* — the caller's inbound buffers
- **[C-17](C-17-message-level-gzip.md)** core *(stale, 5bf4d34e)* — message-level gzip is bounded
- **[C-18](C-18-leak-audit-coverage.md)** the whole repository *(stale, 5bf4d34e)* — the full leak audit, one defect, everything else clean
- **[C-19](C-19-http2-refuses-a-slow-consumer.md)** rounds 213-214, http2 — a consumer that falls behind is failed, by design and by owner decision
- **[C-20](C-20-pre-method-budget-held-for-the-reclaim.md)** round 215, core — the pre-method budget is held until the reclaim, on purpose; looks like a leak, is not
- **[C-21](C-21-header-cap-has-a-floor.md)** round 216, core and http2 — `maxHeaderValueBytes` has a floor; below ~40 the server refuses its own headers and confounds any bench
- **[C-22](C-22-wasm-is-outside-every-gate-script.md)** round 220, wasm — 21 members against 22 packages; wasm's Dart is analysed and formatted by no script, and clean anyway
- **[C-26](C-26-swallowed-grant-failure.md)** round 230, core — `_fcSendGrant`'s swallow is unreachable today (encode cannot throw, a closed channel is a no-op) but load-bearing: with grants planted to throw on a LIVE connection, every arm wedges at the 64 KiB seed
- **[C-25](C-25-web-smoke-catches-a-cancel-deadlock.md)** round 227, core and blob — the web smoke tests DO catch a cancel deadlock; a planted hang went red at the test's own 3s budget. Also: the dart2js `async*` deadlock no longer reproduces on Dart 3.10.1
- **[C-24](C-24-detached-guard-is-unreachable.md)** round 225, core — `_detached` fired 0 times across three scenarios; all 25 wrapped expressions are guarded from the inside, so round 222's green ablation was an unreachable branch and not a coverage gap
- **[C-23](C-23-wasm-guest-promise-rejection-accepted.md)** round 223, wasm — a guest promise rejection is lost on Android and stays lost; **the one record here with no number**, an owner decision to stop pursuing, not a measurement

Large payloads with fragmentation (round 64) and server-side keepalive
(round 63) live in `../backlog/B-06-websocket-lead-list-is-stale.md`: there they
also carry the conclusion about the stale lead list.
