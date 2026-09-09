# Loop backlog

What a lead is and how it links to the rest — [../LOOP.md](../LOOP.md). The line
order below is the rank: **decided-and-ready first, then by damage class, then by
the age of the number.** Re-ranked in round 223, when the owner cleared the
entire awaiting-decision queue.

`(stale, sha)` means code under that lead's paths has changed since its number
was taken. The blocker and the number age separately — see U-21.

## Awaiting an owner decision

**Empty.** All four were answered in round 223: B-17 (refuse at attach), B-01
(out of the loop), B-02 (accepted, C-23), B-19 (close the gate). The three
cost-gated leads were answered in the same pass — B-20 and B-18 approved, B-10
deferred.

## Open — decided, ready to implement

- **[B-19](B-19-close-the-gate-over-wasm.md)** decided (round 223) — `analyze` and `format:check` never see rpc_dart_wasm, the one package shipping Swift and Kotlin. Convert both from `exec:` to `run:`, and verify by ablation on BOTH arms
- **[B-18](B-18-web-guard-is-a-census-not-a-sweep.md)** approved (round 223) — the web guard is a build-and-construct check for nine of twelve packages; plant `async*` cancellation first, it is the class with a history here

## Open

- **[B-05](B-05-isolate-null-credit-silent.md)** open — isolate: zero credit is indistinguishable from an old peer, the failure is silent
- **[B-11](B-11-endpoint-reachability-needs-latency.md)** open, reason "bench" (round 206) — does an endpoint client reach the connection-pool wedge? three benches could not see it; the gap is made of latency
- **[B-06](B-06-websocket-lead-list-is-stale.md)** open, methodological — websocket: the old lead list went stale, the package needs rescanning
- **[B-09](B-09-unfiled-grpc-compat-items.md)** open *(stale, 5bf4d34e)* — unfiled "documented, not fixed" items from private memory
- **[B-03](B-03-wasm-no-package-swift.md)** open, not urgent (round 182) — wasm: no `Package.swift`, and under SPM there is no plugin at all
- **[B-21](B-21-reconnectable-transport-type.md)** open, next major (round 224) — make the reconnect capability a compile-time requirement; moves round 224's runtime refusal to a red squiggle, and fixes nothing currently broken

## Deferred by the owner

- **[B-10](B-10-layers-without-lenses.md)** deferred (round 223) — data, notify and blob have no lens at all: 234 files. **Not to be taken up while core and transport still have work**, however loudly `loop.py stale` names those three directories

## Closed

- **[B-01](B-01-response-metadata-dropped.md)** closed (round 223) — response metadata dropped wholesale; a missing feature, not a defect, so it leaves the loop and becomes ordinary roadmap work. The measurement and the API shape stay on the page
- **[B-02](B-02-wasm-android-promise-rejection.md)** closed (round 223) — wasm guest promise rejection on Android, accepted as [C-23](../checked/C-23-wasm-guest-promise-rejection-accepted.md)
- **[B-04](B-04-isolate-future-timeout-unaudited.md)** closed (round 223) — isolate `Future.timeout` sites swept, all four guarded; the guards are untested, which is [L-04](../lessons/L-04-a-guard-with-no-witness.md)
- **[B-07](B-07-decision-close-on-protocol-error.md)** decided by owner (round 190) — `closeOnProtocolError` defaults to `false`, plus a cap on the violation count
- **[B-08](B-08-decision-closed-transport-error-split.md)** closed (round 201) — the error-type split on a closed transport
- **[B-12](B-12-http2-cancel-kills-the-connection.md)** closed (round 208) — one cancelled stalled call killed the connection; the owner chose "keep reading, fail the call". The upstream package:http2 report is still open
- **[B-13](B-13-parked-sender-outlives-its-call.md)** closed (round 211) — measured: the wake works, 0 waiters with it and 30 without
- **[B-14](B-14-stale-sendcredit-per-abandoned-upload.md)** closed (round 212) — the writer was a late `_fcOnGrant` after teardown; fixed
- **[B-15](B-15-rpc-level-grants-on-http2.md)** closed (round 214) — cooperative backpressure on http2 via rpc-level grants, not built; the behaviour that stands is accepted in [C-19](../checked/C-19-http2-refuses-a-slow-consumer.md)
- **[B-20](B-20-detached-guard-has-no-witness.md)** closed (round 225) — the guard has no witness because nothing reaches it; 0 rejections across three scenarios, all 25 wrapped expressions internally guarded ([C-24](../checked/C-24-detached-guard-is-unreachable.md)). The isolate half stays open in B-04's closing note
- **[B-17](B-17-watermark-lost-through-a-decorator.md)** closed (round 224) — the decorator that erased the stream-id watermark is refused at attach; `handlers ended` went `1 -> 0` with the control unchanged. The compile-time version is [B-21](B-21-reconnectable-transport-type.md)
- **[B-16](B-16-pre-method-byte-budget-release.md)** closed (round 215) — swept, clean; the one row that looks like a leak is the reorder deferral, bounded by `halfOpenStreamTimeout` ([C-20](../checked/C-20-pre-method-budget-held-for-the-reclaim.md))
