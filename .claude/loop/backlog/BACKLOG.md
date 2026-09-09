# Loop backlog

What a lead is and how it links to the rest — [../LOOP.md](../LOOP.md). The line
order below is the rank.

- **[B-01](B-01-response-metadata-dropped.md)** awaiting owner, an API shape (round 141) — response metadata is dropped wholesale
- **[B-02](B-02-wasm-android-promise-rejection.md)** awaiting owner — wasm: an unhandled promise rejection is lost on Android
- **[B-03](B-03-wasm-no-package-swift.md)** open, not urgent (round 182) — wasm: no `Package.swift`, and under SPM there is no plugin at all
- **[B-04](B-04-isolate-future-timeout-unaudited.md)** open (round 67) — isolate: unaudited `Future.timeout` sites, the price is a leaked isolate
- **[B-05](B-05-isolate-null-credit-silent.md)** open — isolate: zero credit is indistinguishable from an old peer, the failure is silent
- **[B-06](B-06-websocket-lead-list-is-stale.md)** open, methodological — websocket: the old lead list went stale, the package needs rescanning
- **[B-07](B-07-decision-close-on-protocol-error.md)** decided by owner (round 190) — `closeOnProtocolError` defaults to `false`, plus a cap on the violation count
- **[B-08](B-08-decision-closed-transport-error-split.md)** closed (round 201) — the error-type split on a closed transport
- **[B-09](B-09-unfiled-grpc-compat-items.md)** open — unfiled "documented, not fixed" items from private memory
- **[B-10](B-10-layers-without-lenses.md)** open — data, notify and blob have no lens at all: 234 files
- **[B-11](B-11-endpoint-reachability-needs-latency.md)** open, reason "bench" (round 206) — does an endpoint client reach the connection-pool wedge? three benches could not see it; the gap is made of latency
- **[B-13](B-13-parked-sender-outlives-its-call.md)** closed (round 211) — measured: the wake works, 0 waiters with it and 30 without
- **[B-14](B-14-stale-sendcredit-per-abandoned-upload.md)** closed (round 212) — the writer was a late `_fcOnGrant` after teardown; fixed
- **[B-16](B-16-pre-method-byte-budget-release.md)** open, reason "cost" (round 214) — is the pre-method byte budget released on every teardown path? the last stateful field RPC-05 has not swept, and the one whose leak is unauthenticated remote memory exhaustion
- **[B-15](B-15-rpc-level-grants-on-http2.md)** closed (round 214) — cooperative backpressure on http2 via rpc-level grants, not built; the behaviour that stands is accepted in [C-19](../checked/C-19-http2-refuses-a-slow-consumer.md)
- **[B-12](B-12-http2-cancel-kills-the-connection.md)** closed (round 208) — http2: one cancelled stalled call killed the connection for good; the owner chose "keep reading, fail the call", shipped in 208. The upstream package:http2 report is still open
