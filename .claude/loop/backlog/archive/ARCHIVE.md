# Closed leads

What a lead is — [../../LOOP.md](../../LOOP.md). The live register is
[../BACKLOG.md](../BACKLOG.md); this is where a lead goes when it closes.

**This directory is deliberately invisible to `loop.py`.** `entity_files` globs
`backlog/*.md` and does not recurse, so nothing here is parsed as a lead,
counted by `status`, ranked by `next`, or required to carry a line in
`BACKLOG.md`. That is the whole mechanism: a closed lead stops competing for
attention with a live one without being deleted.

**Why they are moved rather than struck through in place.** Round 232 is the
precedent — the selector read an ARCHIVE as a decision, because
`pending_decisions` tested a section for non-empty prose and superseded text is
still prose. Five rounds opened by overruling it by hand. A closed lead kept
inline is the same shape: text that reads live to anything that does not parse
its status.

**Nothing here is dead.** A closed lead is the evidence that a question was
answered, and several have been re-opened by a later measurement — B-70 sat
"nothing left to take" for twelve rounds and round 444 found a reachable defect
in it. Read one before re-deriving its subject; `git log --follow` still works
across the move.

**Inbound links were repointed when these moved** (`../backlog/B-NN-*.md` ->
`../backlog/archive/B-NN-*.md`), by hand, because `loop.py lint` does not check
links inside the loop's own data. L-09 is the lesson: a delete has an inbound
half, and the last time it was skipped it left 19 dangling links across 11 files
for the owner to find. If you move anything else in here, grep for it first.

## The register

Ordered by number. The status line is each lead's own frontmatter.

- **[B-01](B-01-response-metadata-dropped.md)** closed (round 223) — response metadata is dropped
- **[B-02](B-02-wasm-android-promise-rejection.md)** closed (round 223) — wasm android promise rejection
- **[B-04](B-04-isolate-future-timeout-unaudited.md)** closed (round 223) — isolate future timeout unaudited
- **[B-05](B-05-isolate-null-credit-silent.md)** closed (round 229) — the zero-grant half fixed; the logging half is below the bar
- **[B-06](B-06-websocket-lead-list-is-stale.md)** closed (round 234) — the websocket lead list was stale
- **[B-07](B-07-decision-close-on-protocol-error.md)** closed (round 208) — option 2 shipped; the upstream report is still open
- **[B-08](B-08-decision-closed-transport-error-split.md)** closed (round 201) — closed-transport error type split
- **[B-09](B-09-unfiled-grpc-compat-items.md)** closed (round 429) — the three gRPC-compat items
- **[B-11](B-11-endpoint-reachability-needs-latency.md)** closed (round 415) — endpoint reachability needs latency
- **[B-12](B-12-http2-cancel-kills-the-connection.md)** closed (round 212) — mechanism pinned to a late grant, fixed
- **[B-13](B-13-parked-sender-outlives-its-call.md)** closed (round 211) — measured, the wake works: 0 waiters with it, 30 without
- **[B-14](B-14-stale-sendcredit-per-abandoned-upload.md)** closed (round 214) — stale send credit per abandoned upload
- **[B-15](B-15-rpc-level-grants-on-http2.md)** closed (round 215) — swept, clean; the budget is released on every path
- **[B-16](B-16-pre-method-byte-budget-release.md)** closed (round 225) — pre-method byte budget release
- **[B-17](B-17-watermark-lost-through-a-decorator.md)** closed (round 224) — watermark lost through a decorator
- **[B-18](B-18-web-guard-is-a-census-not-a-sweep.md)** closed (round 227) — the web guard was a census, not a sweep
- **[B-19](B-19-close-the-gate-over-wasm.md)** closed (round 226) — close the gate over wasm
- **[B-20](B-20-detached-guard-has-no-witness.md)** closed (round 223) — all four sites swept and guarded
- **[B-21](B-21-reconnectable-transport-type.md)** closed (round 430) — IRpcReconnectableTransport
- **[B-22](B-22-paused-consumer-never-repays-the-pool.md)** closed (round 250) — a paused consumer never repaid the pool
- **[B-23](B-23-pre-201-knowledge-outside-the-journal.md)** closed (round 415) — pre-201 knowledge outside the journal
- **[B-24](B-24-frame-channel-buffer-is-an-ordering-coincidence.md)** closed (round 266) — the frame channel buffer was an ordering coincidence
- **[B-25](B-25-sequential-reconnect-orphans-a-connection.md)** closed (round 273) — REFUTED
- **[B-26](B-26-timeout-bounds-the-wait-not-the-body-read.md)** closed (round 262) — the timeout bounded the wait, not the body read
- **[B-27](B-27-a-tcp-syn-builds-an-endpoint.md)** closed (round 287) — a TCP SYN built an endpoint
- **[B-28](B-28-metadata-is-exempt-from-flow-control.md)** closed (round 350) — bounded the buffer; pacing was the wrong tool
- **[B-29](B-29-the-isize-bomb-is-unbounded-on-web.md)** closed (round 427) — the ISIZE residual documented
- **[B-30](B-30-russian-comments-outside-the-mandate.md)** closed (round 441) — the decided half swept; the owner chose to close the rest
- **[B-31](B-31-the-web-channel-has-no-reachable-witness.md)** closed (round 428) — the isolate web channel's witness
- **[B-32](B-32-zero-copy-unary-may-not-dispatch.md)** closed (round 415) — bookkeeping caught up with the content
- **[B-34](B-34-http2-does-not-check-outbound-metadata.md)** closed (round 340) — fixed with the two lines rpc_dart_http already has
- **[B-36](B-36-the-abandon-timer-fabricates-a-success.md)** closed (round 415) — leave the breaker half-open
- **[B-37](B-37-endpoints-getter-excludes-peers.md)** closed (round 420) — the endpoints getter excluded peers
- **[B-39](B-39-websocket-send-throws-into-the-root-zone.md)** closed (round 443) — the documentation IS the fix; the guard reaches nobody
- **[B-40](B-40-method-path-from-key-drops-dots.md)** closed (round 415) — split on the LAST dot
- **[B-41](B-41-android-base64-on-the-main-thread.md)** closed (round 415) — the move is NOT shipped; the negative is the deliverable
- **[B-42](B-42-ios-strip-failfast-unwitnessed.md)** closed (round 365) — all five witnesses pass on iOS 18.6
- **[B-43](B-43-ios-send-order-is-a-convention.md)** closed (round 415) — 10000 frames in order on both platforms
- **[B-44](B-44-client-stream-first-frame-loses-its-metadata.md)** closed (round 379) — the client-stream first frame lost its metadata
- **[B-45](B-45-two-owners-start-the-same-endpoint.md)** closed (round 381) — two owners started the same endpoint
- **[B-46](B-46-an-empty-blob-id-is-silently-generated.md)** closed (round 415) — an empty blob id is refused, not generated
- **[B-47](B-47-the-initial-send-window-is-smaller-than-a-message.md)** closed (round 380) — 156.25 MiB unbounded against 4.06 MiB windowed
- **[B-48](B-48-the-isolate-chrome-arm-never-connects.md)** closed (round 379) — the isolate chrome arm never connected
- **[B-49](B-49-request-sink-has-no-backpressure.md)** closed (round 389) — measured, and the consequence was worse than the reading
- **[B-50](B-50-a-client-stream-cannot-report-a-short-read.md)** closed (round 390) — the signal existed and was not exposed
- **[B-51](B-51-the-request-direction-of-the-bidi-pump.md)** closed (round 375) — the request direction of the bidi pump
- **[B-52](B-52-the-concurrent-reconnect-witness-was-deleted.md)** closed (round 415) — the concurrent reconnect witness was deleted
- **[B-53](B-53-an-http2-reset-racing-responses-kills-the-connection.md)** closed (round 398) — the ordinary half fixed in 388, the rest by http2 3.1.0
- **[B-54](B-54-the-producer-runs-on-after-the-call-ends.md)** closed (round 370) — the producer ran on after the call ended
- **[B-55](B-55-the-response-sink-swallows-its-source-error.md)** closed (round 382) — the response sink swallowed its source error
- **[B-56](B-56-five-copies-of-one-subscription-discipline.md)** closed (round 426) — 8 of 10 sites unified; sites 1 and 3 declined, accepted
- **[B-57](B-57-every-unary-handler-subscribes-to-the-connection.md)** closed (round 417) — every unary handler subscribed to the connection
- **[B-58](B-58-a-framing-violation-counts-toward-nothing.md)** closed (round 416) — a framing violation counted toward nothing
- **[B-59](B-59-a-peer-arriving-while-stopped-is-abandoned.md)** closed (round 421) — a peer arriving while stopped was abandoned
- **[B-60](B-60-the-websocket-drain-admits-everything.md)** closed (round 414) — markDraining() added and called; 1347 admitted became 3
- **[B-61](B-61-http2-never-notices-it-is-disconnected.md)** closed (round 421) — http2 never noticed it was disconnected
- **[B-62](B-62-the-envelope-nobody-unwraps.md)** closed (round 413) — the status half fixed; the unwrapper is routing only
- **[B-63](B-63-one-mechanic-many-homes.md)** closed (round 422) — one mechanic, many homes
- **[B-64](B-64-four-callers-disagree-about-what-ends-a-call.md)** closed (rounds 415, 416) — RpcCallerTrailer owns the rule for all five shapes
- **[B-65](B-65-a-cancelled-unary-handler-still-answers.md)** closed (round 415) — suppress, and say so
- **[B-66](B-66-two-http-status-tables-one-retryability.md)** closed (round 418) — 504 is retryable, and the same answer on both transports
- **[B-67](B-67-three-method-path-limits.md)** closed (round 417) — three method-path limits
- **[B-68](B-68-irpcserver-stop-cannot-express-a-drain.md)** closed (round 423) — IRpcServer.stop could not express a drain
- **[B-69](B-69-pair-builds-a-client-production-never-builds.md)** closed (round 420) — pair() built a client production never builds
- **[B-70](B-70-the-unverified-half-of-the-duplication-sweep.md)** closed (round 444) — item 5 measured and fixed; the rest SPLIT into B-72..B-87. Keeps the 36-item routing table and the six claims that died on the re-read

**Not here, and deliberately**: B-03, B-10, B-33, B-35 and B-38 are closed to
nobody — they are decided-and-waiting or deferred, which is live work. They stay
in [../BACKLOG.md](../BACKLOG.md).
