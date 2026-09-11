# Loop backlog

What a lead is and how it links to the rest — [../LOOP.md](../LOOP.md). The line
order below is the rank: **decided-and-ready first, then by damage class, then by
the age of the number.** Re-ranked in round 223, when the owner cleared the
entire awaiting-decision queue.

`(stale, sha)` means code under that lead's paths has changed since its number
was taken. The blocker and the number age separately — see U-21.

**Curate after round 327 classified all eight stale leads instead of trusting
the flag**, and the first pass at it was wrong — a guess that "most of this is
the lint rounds" survived until the `git log`s were actually read:

```
                 commits since its sha        verdict
  B-28                 2   both docs          mechanical
  B-29                 1   the lint floor     mechanical
  B-31                 1   the lint floor     mechanical
  B-32                 1   the lint floor     mechanical
  B-11                 7   2 behavioural      GENUINELY AGED
  B-21                12   8 fix() + 1 refactor!   GENUINELY AGED
  B-09, B-23          29   pre-201 shas       GENUINELY AGED
```

Four are `(stale, mechanical)`: their numbers stand and re-measuring them is work
with a known answer. **B-11 and B-21 are not** — B-21 in particular has eight
`fix(rpc_dart)` commits across `client_connection.dart` and `transport.dart`
since its number was taken, which is exactly the shape round 319 found under
RPC-02. They are ranked accordingly and marked the ordinary way.

## Awaiting an owner decision

Re-sorted in the audit after round 287, which found this section holding one
CLOSED lead and a paragraph of orphaned prose while the two leads that actually
await a decision sat under "Open". Both are MEASURED; what is missing is a
choice about what the library promises, not a number.

- **[B-28](B-28-metadata-is-exempt-from-flow-control.md)** open, MEASURED (round 282) — metadata is never paced (4000 sends, 32 MiB, none blocked, against a control that parks at exactly the window) **and nothing catches it**: these frames land in the per-stream `StreamController`, unweighed and uncapped, not in the bounded broadcast. Flow control is the only thing in front of it, and metadata walks past it. **Affects every channel transport, websocket included.** Either charge metadata against the send window — making `sendMetadata` a call that can block, which it never has been — or bound the per-stream controller, turning a flood into a stream failure rather than backpressure
- **[B-34](B-34-http2-does-not-check-outbound-metadata.md)** CLOSED (round 340 — fixed, two lines, `+206 → +210`) — MEASURED (round 339) — RPC-10 applied to `RpcChannelTransport.sendMetadata`, which validates outbound metadata against the policy. websocket/wasm/isolate inherit it; `rpc_dart_http` ported it to both halves; **http2 did not** — its only `validateMetadata` is inbound. It is not unchecked (`_headerValue` rejects non-printable-ASCII, and both arms refuse a Cyrillic value) but a hardcoded charset check is not a policy: under `maxHeaders: 32, maxHeaderValueBytes: 64`, **64 headers, a 200-char value and a header name with a space were all ACCEPTED** where the shared layer threw `ArgumentError`. Blast radius is ONE stream — a clean call before and after each violation returns `ok(x)` — which is why it is a lead, not a round. Fix is two lines; the one question in it is that outbound validation refuses against the SENDER's policy where today the PEER's decides, which differs for an asymmetric deployment. **Keeper from the measuring:** a first pass used `maxHeaders: 4`, below what an ordinary request carries, so the peer refused every call including the control — and it read exactly like the violating frame had poisoned the connection
- **[B-33](B-33-blob-adapters-disagree-on-a-missing-blob.md)** open, owner scope decision (round 318) — `IBlobRepository.deleteBlob` promises only "returns `true` when something was removed", and on the SAME input (blob missing, `expectedVersion` set) `in_memory` **throws StateError** while `webdav` **returns false**. These are interchangeable by design, so a caller written against one silently takes the other branch on the other. Two more implementations (minio, sqlite) were not compared; `IDataStorageAdapter` and `INotifyRepository` have the same structure and were not looked at. Aggravated by `*_postgres`/`*_minio` being excluded from `test:unit` — the least-exercised adapters are where this accumulates. Out of scope: core and transport only for now; sits with B-10
- **[B-32](B-32-zero-copy-unary-may-not-dispatch.md)** open, but the alarming half is ANSWERED and WRONG (round 316) — round 315 left the zero-copy generic asymmetry open; reading the dispatch produced a convincing argument that unary should throw, because the registry's static type is `<Object, Object>` and Dart function parameters are contravariant. It does not throw: **Dart generics are reified**, so `callUnaryHandler` runs with the instance's real type arguments, and `unsendable_direct_object_test.dart:120` already covers exactly the shape predicted to fail. One grep answered what a page of type reasoning did not. What remains open is only the cosmetic unification of the two registration shapes, which RPC-25 declines (no drift, no rule)
- **[B-31](B-31-the-web-channel-has-no-reachable-witness.md)** open, owner decision (round 313) — round 310's isolate web `send` fix is analyser- and sibling-verified but has **no test**, and the only route to one widens the surface. Through the public API needs a real `Worker`, i.e. a browser the ordinary gate never runs. Directly on the channel would be one line — the class takes its transmit function as a constructor parameter, so a throwing stub reaches the defect with no Worker — but `_WebMultiplexedChannel` is library-private, and Dart privacy is per-library, so `src/`-importing does not help the way it did in 307. That leaves `@visibleForTesting`, which is an API-shape trade rather than a bug fix. A cheaper variant (extract the send-failure POLICY and test that) witnesses the decision but not the integration
- **[B-30](B-30-russian-comments-outside-the-mandate.md)** open, MEASURED (round 303) — the root `CLAUDE.md` says "English for code, comments, and logs"; **25 lib files are in Russian**, and only the three http2 ones are inside the owner's five-package mandate. `rpc_data` holds 16 of them, in `models.dart`, the contract and the repository interfaces — the API surface its users read first, on a package that is PUBLISHED, so dartdoc renders it. One is `.g.dart`, so that one means fixing the generator's source. Not swept in 303 because the mandate names five packages and these are none of them.
  **Curate after 327 re-took the count and the lead was measuring the wrong half.** `lib/` is 23 files today. `test/` and `example/` across core and transport hold **55 more** — more than twice the lead's whole number, never counted, and unlike the `lib/` ones they are squarely inside the owner's current core-and-transport scope. Rounds 325 and 326 read through several of them while raising the lint floor (`rpc_responder_endpoint_test.dart`, `responder_dispose_example.dart`, `http2_rpc_integration_test.dart`) and touched the code without touching the comments, because that was not the round's job. The in-scope half is the cheaper and larger one
- **[B-29](B-29-the-isize-bomb-is-unbounded-on-web.md)** open, MEASURED (round 286) — a gzip payload whose ISIZE understates it is refused in **12 ms on the VM and 15980 ms on dart2js**, because `boundedInflate` is `=> null` there and the limit runs on `result.length` after the output exists. ~65 KiB of wire buys 64 MiB and sixteen seconds of the event loop. **No fix is worth proposing** — a compressed-size heuristic would refuse ordinary traffic at deflate's 1032:1 ceiling, and `package:archive` has no incremental inflater on web — so what remains is documenting the residual or accepting a lower effective limit there

## Open — decided, ready to implement

- **websocket's `pingInterval` is still opt-in.** Not a numbered lead, because round 287 measured the http2 half and named this one rather than changing it blind; the websocket server's own doc carries the same shape (`pingInterval 3s : endpoints 0, contracts disposed 5 by t+10s`). The argument that closed B-27 transfers, and the change is one default on a different API surface

## Open

- **[B-23](B-23-pre-201-knowledge-outside-the-journal.md)** open, reason "cost" (curate after 234) *(stale, aba26aa3 — 94 commits)* — 52,203 words of pre-201 knowledge sit outside the journal, where nothing routes to or ages them. NOT duplication: `checked/` imported the negatives, the SHAPES and METHODS stayed out. Two lenses recovered (RPC-16, RPC-17); ~30 dossiers left, and the four METHOD entries are the highest value
- **[B-26](B-26-timeout-bounds-the-wait-not-the-body-read.md)** closed (round 273), **REFUTED** — the prediction was that `.timeout()` on `readBody()` leaves its `await for` consuming; it does not. 384 KiB accepted after the 408 against 16384 KiB in 49 ms with the deadline off, because dart:io detaches the body of a finished exchange. Wrong for a reason that is not in our code; kept as C-31
- **[B-25](B-25-sequential-reconnect-orphans-a-connection.md)** closed (round 262), PARKED by the owner — **a connection leak, measured and unexplained.** A sequential http2 reconnect leaves a DISCARDED connection open about 1.3% of the time (5 in 390 direct cycles, always ordinal 1 or 2). Six rounds eliminated three accounts — socket.destroy() as the fix, the dropped terminate() Future, the header-block guard — without finding the cause. The one untried variable, a discard racing a concurrent connect, is written up with its three-arm design. Reopen when it costs something real
- **[B-24](B-24-frame-channel-buffer-is-an-ordering-coincidence.md)** closed (round 250) — the frame channel's inbound controller now buffers like the other six. Shipped with NO canary on the owner's decision: no construction path loses a frame today, so a witness would have had to invent the very await whose absence makes the code safe
- **[B-21](B-21-reconnectable-transport-type.md)** open, next major (round 224) *(stale, ed1a54bc — **12 commits, 8 of them `fix()`**)* — make the reconnect capability a compile-time requirement; moves round 224's runtime refusal to a red squiggle, and fixes nothing currently broken. **Ranked up by the curate after 327**: its paths (`client_connection.dart`, `transport.dart`) have taken more behavioural churn than any other lead's since its number, so "fixes nothing currently broken" is the claim most likely to have decayed
- **[B-11](B-11-endpoint-reachability-needs-latency.md)** open, reason "bench" (round 206) *(stale, c48a14d8 — 7 commits, 2 behavioural)* — does an endpoint client reach the connection-pool wedge? three benches could not see it; the gap is made of latency
- **[B-09](B-09-unfiled-grpc-compat-items.md)** open *(stale, 5bf4d34e — 29 commits)* — unfiled "documented, not fixed" items from private memory
- **[B-03](B-03-wasm-no-package-swift.md)** open, not urgent (round 182) — wasm: no `Package.swift`, and under SPM there is no plugin at all

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
