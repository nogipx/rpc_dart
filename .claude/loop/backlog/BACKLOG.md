# Loop backlog

What a lead is and how it links to the rest — [../LOOP.md](../LOOP.md). The line
order below is the rank: **decided-and-ready first, then by damage class, then by
the age of the number.** Re-ranked in round 223, when the owner cleared the
entire awaiting-decision queue.

`(stale, sha)` means code under that lead's paths has changed since its number
was taken. The blocker and the number age separately — see U-21.

## Awaiting an owner decision

Re-sorted in the audit after round 287, which found this section holding one
CLOSED lead and a paragraph of orphaned prose while the two leads that actually
await a decision sat under "Open". Both are MEASURED; what is missing is a
choice about what the library promises, not a number.

- **[B-28](B-28-metadata-is-exempt-from-flow-control.md)** open, MEASURED (round 282) — metadata is never paced (4000 sends, 32 MiB, none blocked, against a control that parks at exactly the window) **and nothing catches it**: these frames land in the per-stream `StreamController`, unweighed and uncapped, not in the bounded broadcast. Flow control is the only thing in front of it, and metadata walks past it. **Affects every channel transport, websocket included.** Either charge metadata against the send window — making `sendMetadata` a call that can block, which it never has been — or bound the per-stream controller, turning a flood into a stream failure rather than backpressure
- **[B-29](B-29-the-isize-bomb-is-unbounded-on-web.md)** open, MEASURED (round 286) — a gzip payload whose ISIZE understates it is refused in **12 ms on the VM and 15980 ms on dart2js**, because `boundedInflate` is `=> null` there and the limit runs on `result.length` after the output exists. ~65 KiB of wire buys 64 MiB and sixteen seconds of the event loop. **No fix is worth proposing** — a compressed-size heuristic would refuse ordinary traffic at deflate's 1032:1 ceiling, and `package:archive` has no incremental inflater on web — so what remains is documenting the residual or accepting a lower effective limit there

## Open — decided, ready to implement

- **websocket's `pingInterval` is still opt-in.** Not a numbered lead, because round 287 measured the http2 half and named this one rather than changing it blind; the websocket server's own doc carries the same shape (`pingInterval 3s : endpoints 0, contracts disposed 5 by t+10s`). The argument that closed B-27 transfers, and the change is one default on a different API surface

## Open

- **[B-23](B-23-pre-201-knowledge-outside-the-journal.md)** open, reason "cost" (curate after 234) — 52,203 words of pre-201 knowledge sit outside the journal, where nothing routes to or ages them. NOT duplication: `checked/` imported the negatives, the SHAPES and METHODS stayed out. Two lenses recovered (RPC-16, RPC-17); ~30 dossiers left, and the four METHOD entries are the highest value
- **[B-26](B-26-timeout-bounds-the-wait-not-the-body-read.md)** closed (round 273), **REFUTED** — the prediction was that `.timeout()` on `readBody()` leaves its `await for` consuming; it does not. 384 KiB accepted after the 408 against 16384 KiB in 49 ms with the deadline off, because dart:io detaches the body of a finished exchange. Wrong for a reason that is not in our code; kept as C-31
- **[B-25](B-25-sequential-reconnect-orphans-a-connection.md)** closed (round 262), PARKED by the owner — **a connection leak, measured and unexplained.** A sequential http2 reconnect leaves a DISCARDED connection open about 1.3% of the time (5 in 390 direct cycles, always ordinal 1 or 2). Six rounds eliminated three accounts — socket.destroy() as the fix, the dropped terminate() Future, the header-block guard — without finding the cause. The one untried variable, a discard racing a concurrent connect, is written up with its three-arm design. Reopen when it costs something real
- **[B-24](B-24-frame-channel-buffer-is-an-ordering-coincidence.md)** closed (round 250) — the frame channel's inbound controller now buffers like the other six. Shipped with NO canary on the owner's decision: no construction path loses a frame today, so a witness would have had to invent the very await whose absence makes the code safe
- **[B-11](B-11-endpoint-reachability-needs-latency.md)** open, reason "bench" (round 206) — does an endpoint client reach the connection-pool wedge? three benches could not see it; the gap is made of latency
- **[B-09](B-09-unfiled-grpc-compat-items.md)** open *(stale, 5bf4d34e)* — unfiled "documented, not fixed" items from private memory
- **[B-03](B-03-wasm-no-package-swift.md)** open, not urgent (round 182) — wasm: no `Package.swift`, and under SPM there is no plugin at all
- **[B-21](B-21-reconnectable-transport-type.md)** open, next major (round 224) — make the reconnect capability a compile-time requirement; moves round 224's runtime refusal to a red squiggle, and fixes nothing currently broken

## Deferred by the owner

- **[B-10](B-10-layers-without-lenses.md)** deferred (round 223) — data, notify and blob have no lens at all: 234 files. **Not to be taken up while core and transport still have work**, however loudly `loop.py stale` names those three directories

## Closed

- **[B-27](B-27-a-tcp-syn-builds-an-endpoint.md)** closed (round 287) — a TCP SYN built the transport, the endpoint and the application's contracts before a byte arrived: 200 silent sockets gave 200 endpoints, against 0 on websocket. Closed in two halves, because it needed two mechanisms: `prefaceTimeout` (275) bounds a peer that never speaks HTTP/2, and `pingInterval` defaulting to 30s (287) bounds one that speaks the preface and then goes silent — 24 preface bytes buy past the first. Fix 1, deferring the construction itself, is left and de-urgentised
- **[B-22](B-22-paused-consumer-never-repays-the-pool.md)** closed (round 266) — **a wedged connection, fixed in one line.** A PAUSED consumer never receives `done`, so its `onCancel` never ran and `_fcForget` skipped the repay because a listener existed: the bytes stayed owed forever. Now repaid unconditionally, 1024 -> 3072 KiB. The double credit that guard prevented is absorbed by the receive-side clamp — established after five witnesses failed to observe it (253, 254, 262-264) and one read explained why (265)
- **[B-06](B-06-websocket-lead-list-is-stale.md)** closed (round 234) — the websocket rescan is finished. 233 did a third and named the unread file; 234 read it and it held a third RPC-03 instance: on a drop the PEER starts, the id cursor was rewound by the very close that reports the drop
- **[B-01](B-01-response-metadata-dropped.md)** closed (round 223) — response metadata dropped wholesale; a missing feature, not a defect, so it leaves the loop and becomes ordinary roadmap work. The measurement and the API shape stay on the page
- **[B-02](B-02-wasm-android-promise-rejection.md)** closed (round 223) — wasm guest promise rejection on Android, accepted as [C-23](../checked/C-23-wasm-guest-promise-rejection-accepted.md)
- **[B-04](B-04-isolate-future-timeout-unaudited.md)** closed (round 223) — isolate `Future.timeout` sites swept, all four guarded; the guards are untested, which is [L-04](../lessons/L-04-a-guard-with-no-witness.md)
- **[B-07](B-07-decision-close-on-protocol-error.md)** decided by owner (round 190) — `closeOnProtocolError` defaults to `false`, plus a cap on the violation count
- **[B-08](B-08-decision-closed-transport-error-split.md)** closed (round 201) — the error-type split on a closed transport
- **[B-12](B-12-http2-cancel-kills-the-connection.md)** closed (round 208) — one cancelled stalled call killed the connection; the owner chose "keep reading, fail the call". The upstream package:http2 report is still open
- **[B-13](B-13-parked-sender-outlives-its-call.md)** closed (round 211) — measured: the wake works, 0 waiters with it and 30 without
- **[B-14](B-14-stale-sendcredit-per-abandoned-upload.md)** closed (round 212) — the writer was a late `_fcOnGrant` after teardown; fixed
- **[B-15](B-15-rpc-level-grants-on-http2.md)** closed (round 214) — cooperative backpressure on http2 via rpc-level grants, not built; the behaviour that stands is accepted in [C-19](../checked/C-19-http2-refuses-a-slow-consumer.md)
- **[B-18](B-18-web-guard-is-a-census-not-a-sweep.md)** closed (round 227) — premise corrected: for the cancel class the web smoke tests are a working detector, shown by ablation ([C-25](../checked/C-25-web-smoke-catches-a-cancel-deadlock.md)); and the `async*` class it named no longer reproduces on Dart 3.10.1
- **[B-19](B-19-close-the-gate-over-wasm.md)** closed (round 226) — `analyze`, `format:check` and `format` now cover rpc_dart_wasm; verified on four arms, a planted violation goes red in wasm and still goes red in a member
- **[B-05](B-05-isolate-null-credit-silent.md)** closed (round 229) — a peer whose first grant was ZERO was read as pre-flow-control and got flooded: 800 KiB through a 64 KiB window, 16 KiB after. The logging half is a diagnostic and stays unfixed
- **[B-20](B-20-detached-guard-has-no-witness.md)** closed (round 225) — the guard has no witness because nothing reaches it; 0 rejections across three scenarios, all 25 wrapped expressions internally guarded ([C-24](../checked/C-24-detached-guard-is-unreachable.md)). The isolate half stays open in B-04's closing note
- **[B-17](B-17-watermark-lost-through-a-decorator.md)** closed (round 224) — the decorator that erased the stream-id watermark is refused at attach; `handlers ended` went `1 -> 0` with the control unchanged. The compile-time version is [B-21](B-21-reconnectable-transport-type.md)
- **[B-16](B-16-pre-method-byte-budget-release.md)** closed (round 215) — swept, clean; the one row that looks like a leak is the reorder deferral, bounded by `halfOpenStreamTimeout` ([C-20](../checked/C-20-pre-method-budget-held-for-the-reclaim.md))
