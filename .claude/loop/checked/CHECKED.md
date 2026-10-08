# Checked — do not re-run

What a negative is, how it differs from a lead, and why detector sweeps do not
live here — [../LOOP.md](../LOOP.md).

**`(stale, sha)` does not retract anything.** It means code under that record's
paths has changed since it was measured, so the claim is unverified rather than
wrong. A negative is never deleted; re-measuring one is a round's target, and
`loop.py stale` says when it is due. Marked in the curate pass after round 220,
where 20 of 50 records had aged — almost all of them because rounds 206-220
rewrote `channel_transport.dart` and the three http2 transports.

**Curate after round 327 deliberately did NOT mark the 28 newly-stale records
one by one, and the reason is a number.** Rounds 325 and 326 raised the analysis
floor across core and transport: two commits, `f70775cb` and `1ab3e26e`, 161
files, entirely type annotations, type arguments, import order and tearoffs —
every test count in the workspace unchanged. `stale` computes from path churn and
cannot tell that from a logic change, so it now reports **28 of 34 negatives, 30
of 31 benches and 3 of 4 sweeps** as aged. Marking all of them would set the flag
on nearly every record in the store, which is the same as setting it on none.

The classification is per-record and cheap — one `git log <sha>..HEAD -- <paths>`
— and `../lenses/LENSES.md` carries it for the sweeps, `../backlog/BACKLOG.md`
for the leads, where it found two that are genuinely aged (B-11, B-21) behind six
that are not. **Do that before treating a stale flag here as a reason to
re-measure.** Round 319 is the counterexample that keeps this honest: there the
same assumption was made in the other direction and 19 of 31 commits turned out
to be behavioural.

- **[C-65](C-65-no-foreign-error-reaches-the-http2-header-refusal.md)** round 662 — no foreign error reaches the http2 header refusal
- **[C-66](C-66-the-transport-matrix-is-clean-on-the-web.md)** round 710 — the transport matrix is clean on the web
- **[C-64](C-64-per-call-log-scopes-are-noise.md)** round 608 — per-call log scopes are 0.34 % of a call
- **[C-63](C-63-a-consumed-connection-queue-holds-nothing.md)** round 600 — a consumed connection queue holds nothing
- **[C-62](C-62-the-websocket-rebroadcast-carries-nothing.md)** round 596 — the websocket wrapper's rebroadcast carries nothing on an ordinary call
- **[C-61](C-61-the-audit-intakes-severity-claims-do-not-hold.md)** round 559 — the audit intake's severity claims do not hold
- **[C-60](C-60-the-unary-break-is-deliberate.md)** round 526 — the unary `break` is deliberate, and its warning is reachable
- **[C-59](C-59-the-three-header-builders-agree.md)** round 517 — the three request-header builders agree
- **[C-58](C-58-a-cancelled-asstream-detaches.md)** round 500 — a cancelled asStream subscription detaches, so a reused token does not accumulate
- **[C-57](C-57-a-large-host-to-guest-frame-keeps-its-place.md)** round 492 — a large host-to-guest frame keeps its place, on both platforms
- **[C-56](C-56-the-two-shims-have-not-drifted.md)** round 482 — the two JS shims have not drifted, and are not one shim
- **[C-55](C-55-spm-already-gets-the-plugin.md)** round 473 — an SPM-enabled app already gets this plugin
- **[C-54](C-54-the-parity-rules-never-meet.md)** round 468 — the three parity rules never meet
- **[C-53](C-53-three-id-mechanisms-one-correct-outcome.md)** round 465 — three id-reuse mechanisms, one correct outcome
- **[C-52](C-52-http1-tells-the-consumer-when-a-status-never-came.md)** round 460 — HTTP/1.1 tells the consumer when a status never came
- **[C-51](C-51-http2-does-charge-the-buffered-bytes.md)** round 459 — http2 does charge the buffered bytes, in the layer it shares
- **[C-50](C-50-the-responder-bounds-its-deadline-in-the-pipeline.md)** round 451 — the responder bounds its deadline, in the pipeline
- **[C-49](C-49-the-sweeps-nine-negatives-verified.md)** round 450 — the `ff930001` sweep's nine claimed negatives, verified
- **[C-48](C-48-no-machine-drops-a-send-during-its-factory-await.md)** round 449 — no reconnect machine drops a send during its factory await
- **[C-47](C-47-the-non-ascii-that-must-stay.md)** round 436 — the non-ASCII that must stay
- **[C-46](C-46-a-refused-http2-stream-releases-its-state.md)** round 395 — a refused HTTP/2 stream releases its transport state
- **[C-45](C-45-bidi-over-a-real-isolate.md)** round 385 — bidi over a real isolate, serialized and zero-copy
- **[C-44](C-44-bidi-over-a-real-socket-and-a-round-trip.md)** round 384 — bidi over a real websocket, on a direct link and over a round trip
- **[C-38](C-38-the-lenient-send-is-not-a-lost-message.md)** round 366 — the lenient send after close does not cost a client-stream a message
- **[C-43](C-43-the-subscription-reaches-every-real-transport.md)** round 377 — a bidi subscription reaches every real transport
- **[C-42](C-42-the-bidi-subscription-holds-on-three-wirings.md)** round 376 — the bidi subscription fix holds on three wirings
- **[C-41](C-41-bidi-releases-its-state-on-every-ending.md)** round 372 — a bidi call releases its state on every ending
- **[C-40](C-40-the-four-shapes-agree-on-the-ordinary-edge-cases.md)** round 368 — the four call shapes agree on four edge cases
- **[C-39](C-39-the-flow-control-copies-are-all-watched.md)** round 367 — extracting the flow-control duplication earns nothing
- **[C-37](C-37-per-stream-state-is-reclaimed.md)** round 343 — the hand-rolled transports reclaim their per-stream state
- **[C-36](C-36-construction-argument-parity.md)** round 335 — every other multi-site construction passes the same arguments
- **[C-35](C-35-the-bidi-send-catch-is-unreachable.md)** round 330 — the bidi bridge's send-failure catch cannot be entered
- **[C-34](C-34-the-caller-contract-has-nothing-to-duplicate.md)** round 317 — the caller contract has nothing to duplicate
- **[C-33](C-33-hostile-reflection-requests.md)** round 284 — the reflection service against hostile requests
- **[C-32](C-32-rapid-reset-dispatches-nothing.md)** round 277 — Rapid Reset dispatches no handler
- **[C-31](C-31-the-408-really-does-stop-the-read.md)** round 273 — a `.timeout()` on the body read really does stop the read
- **[C-27](C-27-keep-calling-on-one-connection.md)** round — (pre-201, off-journal; imported in the curate pass after 234) — "Keep calling on one connection" on the other three transports
- **[C-30](C-30-closed-transport-leniency-is-a-contract.md)** round off-journal 176 — A closed RpcChannelTransport is lenient on purpose
- **[C-29](C-29-the-real-scope-of-the-stream-limits.md)** round off-journal 137 — The real scope of the stream limits, and what to design against
- **[C-28](C-28-sibling-batteries-that-came-back-clean.md)** round — (not re-measured) — Sibling batteries that came back clean
- **[C-01](C-01-sustained-load.md)** round off-journal 191 — Ordinary sustained load retains nothing
- **[C-02](C-02-frame-codec-hostile-frames.md)** round 278 — The frame codec against hostile frames
- **[C-03](C-03-ping-flood.md)** round — (not re-measured) — PING flood (CVE-2019-9512) is not a defect
- **[C-04](C-04-peer-chosen-stream-ids.md)** round — (not re-measured) — Peer-chosen stream ids
- **[C-05](C-05-inbound-security-parity.md)** round — (not re-measured) — Parity of the inbound security controls
- **[C-06](C-06-lifecycle-apis-twice.md)** round off-journal 77 — Sweep of the lifecycle APIs
- **[C-07](C-07-outbound-backpressure-websocket.md)** round — (not re-measured) — Outbound backpressure on websocket
- **[C-08](C-08-cancel-reaches-handler-websocket.md)** round — (not re-measured) — Cancellation reaches the handler on websocket
- **[C-09](C-09-half-close-racing-trailers.md)** round — (not re-measured) — Half-close racing the trailers
- **[C-10](C-10-ghost-stream-ids-from-peer.md)** round — (not re-measured) — Ghost stream ids from a hostile SERVER
- **[C-11](C-11-reconnect-with-open-streams.md)** round — (not re-measured) — reconnect() with open streams, and reuse of a live stream's id
- **[C-12](C-12-wasm-byte-pipe.md)** round — (not re-measured) — wasm: the byte pipe
- **[C-13](C-13-wasm-load-close-cycles.md)** round — (not re-measured) — wasm: 40 load/close cycles
- **[C-14](C-14-wasm-real-guest-batteries.md)** round — (not re-measured) — wasm: three batteries against a real guest
- **[C-15](C-15-grpc-listener-and-cancellation.md)** round — (not re-measured) — A real gRPC client: listener resilience and cancellation
- **[C-16](C-16-http2-caller-inbound-buffers.md)** round — (not re-measured) — The http2 caller's inbound buffers
- **[C-17](C-17-message-level-gzip.md)** round — (not re-measured) — Message-level gzip (`grpc-encoding: gzip`)
- **[C-18](C-18-leak-audit-coverage.md)** round off-journal 191 — The full leak audit
- **[C-19](C-19-http2-refuses-a-slow-consumer.md)** round 213 measured, 214 accepted — http2 refuses a consumer that falls behind, by design
- **[C-20](C-20-pre-method-budget-held-for-the-reclaim.md)** round 215 — the pre-method budget is held until the reclaim, on purpose
- **[C-21](C-21-header-cap-has-a-floor.md)** round 216 — `maxHeaderValueBytes` has a floor, and below it nothing works
- **[C-22](C-22-wasm-is-outside-every-gate-script.md)** round 220 — wasm is outside every gate script, and clean anyway
- **[C-26](C-26-swallowed-grant-failure.md)** round 230 — the swallowed grant failure is unreachable, and load-bearing
- **[C-25](C-25-web-smoke-catches-a-cancel-deadlock.md)** round 227 — the web smoke tests do catch a cancel deadlock
- **[C-24](C-24-detached-guard-is-unreachable.md)** round 225 — the detached guard has no witness because nothing reaches it
- **[C-23](C-23-wasm-guest-promise-rejection-accepted.md)** round 223 — a guest promise rejection is reported on iOS and lost on Android

Large payloads with fragmentation (round 64) and server-side keepalive
(round 63) live in `../backlog/archive/B-06-websocket-lead-list-is-stale.md`: there they
also carry the conclusion about the stale lead list.
