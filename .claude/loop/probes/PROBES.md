# Benches

What a bench is and when it counts as valid — [../LOOP.md](../LOOP.md). The
record format — `../../skills/improvement-loop/specs/probe.md`.

Rounds 201-205 worked with one-off probes: bench registration appeared in the
skill after them, so nothing before 206 has a record here.

**`stale (sha)` does not mean broken.** It means the code under the bench's
paths has moved since its control was last run, so the next round to reuse it
repeats that control FIRST. Only a round with a control sets `valid` again.
Marked in the curate pass after round 220.

**Curate after round 327 left all 30 newly-stale benches at `valid`, on
evidence.** The staleness is the lint-floor rounds (325, 326 — 161 mechanical
files, every test count unchanged); see `../checked/CHECKED.md` for the full
argument. Two benches were reused across that boundary and both reproduced their
controls exactly: **P-10** in round 322, all eight cells of its table identical
to round 221's, and **P-08** in round 327, all four rows identical to round
216's — the latter across 111 rounds. Demoting 30 benches to `stale` on churn
that has twice failed to move a control would send the next round rebuilding
apparatus that works.

The rule the spec states still stands and is what those two rounds did: **repeat
the control first, then trust the bench.** That is cheaper than the status field
either way.

- **[P-37](P-37-guard-versus-filter.md)** valid (round 338), core — whether the
  level guard predicts the filter it stands in for, asked at the controller's own
  stream rather than of the guard. Two of four configurations disagreed and one
  was a MUTE. Needs no instrumentation, which is what makes it cheap to re-run
  after any change to `_resolveLevel`
- **[P-36](P-36-discarded-log-strings-every-shape.md)** valid (round 337), core —
  log messages built for a level that discards them, per round trip, on **all
  four call shapes** and under **two logger configurations**. Round 333's
  ancestor took one shape and one configuration and so measured 6 discarded
  messages where serverStream had 42; attaching a real logger at `error` removes
  none of them. Core-only by construction: a wrong guard in a transport leaves
  every cell unchanged
- **[P-35](P-35-upgraded-then-silent.md)** valid (round 288), rpc_dart_websocket —
  P-25's question one stage later: the peer COMPLETES the upgrade and then never
  speaks websocket, so it answers no PING. A raw socket on purpose — a real
  client would answer them, which is the one thing it must not do
- **[P-34](P-34-isize-understates-on-web.md)** valid (round 286), core — **a bench
  that is also the regression test**, because the thing measured is a platform
  difference and the only honest way to show one is the identical code on both
  runtimes. Forges the ISIZE trailer so the fixture builds without `dart:io`;
  asserts the contract, PRINTS the time
- **[P-33](P-33-hostile-reflection-requests.md)** valid (round 284), core —
  P-28's shape aimed at the OTHER hand-rolled parser here, the reflection
  service's request decoder. Prints the response SIZE and not just a verdict,
  which is the only reason its one interesting row is visible
- **[P-32](P-32-rapid-reset-cpu.md)** valid (round 283), http2 — what a flood
  costs an UNRELATED client, measured as a second connection's call latency
  rather than as CPU. Report the WORST case, not the median: only the worst moves
  here, and a median-only reading calls every arm identical
- **[P-31](P-31-metadata-is-never-paced.md)** valid (round 282), core — **the
  first SEND-path bench here**: does this path apply backpressure? A real
  transport pair, a consumer that TOOK a stream and paused, and the observable is
  whether a send blocks. Its control parks at exactly the window, which is what
  makes it a measurement rather than a coincidence
- **[P-30](P-30-pre-method-budget-weighs-payload-only.md)** valid (round 280),
  core — the pre-method budget with the pipeline's admission check TRANSCRIBED
  beside it, because the thing under test is which frames get in and a bench that
  admits everything cannot see it. Carries its own ablation: pass `old` to charge
  the pre-fix expression without touching the library
- **[P-29](P-29-metadata-weighs-characters.md)** valid (round 279), core — P-21
  extended with the shape P-21 lacks: many TINY headers, where characters and
  cost diverge 12x. Two traps it had to survive — the metadata must be DECODED
  from a wire frame or Dart interns the literals and the cost vanishes, and
  `maxRss` one-arm-per-process because `currentRss` went negative
- **[P-28](P-28-hostile-frames.md)** valid (round 278), core — seventeen named
  malformed frames through the real decoder, each with a hand-written header so
  the declared length can lie. Sorts outcomes into typed refusal / short-read /
  **leaked Error**, which is the one that matters
- **[P-27](P-27-rapid-reset.md)** valid (round 277), http2 and core — HTTP/2
  Rapid Reset, and **the only bench here that speaks HTTP/2 to the server without
  rpc_dart's own caller**: reuse it for anything needing frame-level control.
  Carries a `diagnose` arm, which is what caught a fixture that could not
  dispatch a handler at all
- **[P-26](P-26-refused-upgrade-has-no-deadline.md)** valid (round 276),
  rpc_dart_websocket — P-23's shape aimed at the origin gate. Three arms, and the
  REQUEST SHAPE is the load-bearing one: dart:io hands a connection-upgrade
  request no body, so the holding attack is a plain POST and the upgrade-shaped
  one reads as clean
- **[P-25](P-25-a-tcp-syn-builds-an-endpoint.md)** valid (round 274), http2 and
  websocket — what a connection that never speaks costs a server, counted on the
  library's own `endpoints` and a contract-construction counter (RSS moved by
  -28.7 to +0.4 MiB across identical runs and is unusable). Three controls: the
  keepalive arm, the preface arm, and the sibling server
- **[P-24](P-24-read-after-the-408.md)** valid (round 273), rpc_dart_http — does
  the server keep reading after it has answered? Measured as the PEER's send
  pressure with every flush deadlined, so a stopped read is a number rather than
  a hang. The control is the same bench against a server with no deadline
- **[P-23](P-23-the-refusal-path-has-no-deadline.md)** valid (round 272),
  rpc_dart_http — N slowloris sockets against a REJECTION exit, counting how many
  the server lets go inside a window. The control is one header: `application/grpc`
  reaches the guarded read, `text/plain` reaches the unguarded one
- **[P-22](P-22-body-that-never-arrives.md)** valid (round 271), rpc_dart_http and
  the responder pipeline — what a body that never arrives costs, reported as TWO
  budgets: the transport's `pendingRequests` and the pipeline's `openStreams`.
  The control is the ablation, not the completed-request arm, and the `abort`
  arm's 503 is a neighbouring limit
- **[P-21](P-21-metadata-escapes-the-byte-bound.md)** valid (round 245), core
  buffering — which dimension of a frame does the queue's byte bound see? The
  same 64 KiB as payload stops at 256 frames / 16 MiB, as metadata ran to 4096 /
  256 MiB. The unmoving payload arm is the control
- **[P-20](P-20-throwing-state-callback.md)** valid (round 242), core resilience —
  what a throwing user callback costs on the reconnect path. Counts what the
  throw PREVENTED as well as what it emitted: unhandled 1 and transports built 0
  against a control's 0 and 2
- **[P-19](P-19-sequential-reconnect-orphan-rate.md)** valid (round 241),
  rpc_dart_http2 — how often does a SEQUENTIAL reconnect orphan a connection?
  5 in 390 direct cycles, 0 in 90 through the stalling proxy, and it names WHICH
  of the three connections leaked, which is what separates this from the
  concurrent defect. Underpowered for judging a fix: read its last paragraph
- **[P-18](P-18-early-frames-through-the-proxy.md)** valid (round 240), core
  resilience and transports — do frames that arrived before the app subscribed
  survive a hop? Two controls, because one cannot tell "never existed" from
  "dropped here": 0 late through the proxy against 1 early through it and 1
  straight off the transport. Its first build measured nothing and says why
- **[P-17](P-17-retry-until-the-peer-returns.md)** valid (round 238), reconnect —
  does the recovery API work more than ONCE? Server down, four failed attempts,
  server back, a real call — twice. Records both ways it lied first: the rig
  closing its own client, and an ablation aimed at the wrong observable
- **[P-16](P-16-hpack-reference-flood.md)** valid (round 237), http2 headers —
  what does a header block cost once decoded? Attributes the decoder and the
  adapter separately: +7 MiB vs +258 MiB for the same 63 KiB block, with
  `distinct: 1` the number that refuted the first hypothesis
- **[P-15](P-15-pending-queue-dimension.md)** valid (round 236), core buffering —
  which dimension does the unlistened queue bound? Same pendingCount at three
  payload sizes while the retained bytes scale 64 -> 256 -> 1024 MiB; +549 vs
  +2 MiB through a real transport. Records the two RSS traps it was rebuilt for
- **[P-14](P-14-detach-with-a-throwing-cancel.md)** valid (round 235), core
  resilience — does a throwing `onCancel` on a user-supplied transport abandon
  it? One arm differs by that throw alone: leaked 0 vs 1, unhandled zone errors
  0 vs 1, and the reconnect that never happened
- **[P-13](P-13-ids-after-a-peer-started-reconnect.md)** valid (round 234), websocket
  and core reconnect — does the stream-id sequence survive a reconnect the PEER
  started? Two arms differing by one event: 1 then 3 when this side calls
  `reconnect()`, 1 then 1 when the socket dies first, and a dead call's
  half-close then ended a live one
- **[P-12](P-12-zero-grant-reads-as-legacy.md)** valid (round 229), core transports —
  is a zero grant read as a peer that does not participate? A FOREIGN peer driven
  at the channel level, which is the only way to reach the path: 800 KiB through
  a 64 KiB window against 20 KiB in the control
- **[P-11](P-11-connection-debt-with-a-paused-consumer.md)** valid (round 228), core transports —
  does the connection pool come back from a consumer that stops? Round 206's
  bench with a third arm; three controls reach 3072 KiB, the paused one wedges
  at the pool. Supersedes P-01, which is the same file before that arm
- **[P-10](P-10-parked-sender-learns.md)** valid (round 221), core transports —
  does a parked sender learn its call is over? Written in 210, registered in 221
  once an ablation showed it can see a credit hang
- **[P-09](P-09-watermark-survives-a-decorator.md)** valid (round 217), core resilience —
  does the stream-id watermark survive a user's decorator?
- **[P-08](P-08-refusal-survives-a-tight-cap.md)** valid (round 216), http2 and core —
  does a refusal survive the policy it just enforced?
- **[P-07](P-07-pre-method-budget-returns.md)** valid (round 215), core endpoint —
  does the pre-method byte budget come back?
- **[P-06](P-06-handler-slots-return.md)** valid (round 214), core endpoint —
  does a handler slot come back on every teardown path?
- **[P-05](P-05-slow-consumer-is-throttled.md)** valid (round 213),
  rpc_dart_http2 — a consumer that falls behind is failed; ACCEPTED behaviour,
  see [C-19](../checked/C-19-http2-refuses-a-slow-consumer.md)
- **[P-04](P-04-parked-waiters-drain.md)** stale (0d071c55), core transports —
  does an abandoned upload leave its sender parked?
- **[P-03](P-03-wrapper-keeps-the-bound.md)** stale (906437a2), rpc_dart_http2 —
  does a transport bound survive `RpcHttp2Server.transportWrapper`?
- **[P-02](P-02-http2-aborted-call-pool.md)** stale (1d5efdda), rpc_dart_http2 —
  does an http2 connection survive a cancelled stalled call?
- **[P-01](P-01-connection-window-debt.md)** stale (c48a14d8), core transports —
  how much a sender gets out before the connection pool wedges
