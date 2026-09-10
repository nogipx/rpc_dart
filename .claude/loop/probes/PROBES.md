# Benches

What a bench is and when it counts as valid — [../LOOP.md](../LOOP.md). The
record format — `../../skills/improvement-loop/specs/probe.md`.

Rounds 201-205 worked with one-off probes: bench registration appeared in the
skill after them, so nothing before 206 has a record here.

**`stale (sha)` does not mean broken.** It means the code under the bench's
paths has moved since its control was last run, so the next round to reuse it
repeats that control FIRST. Only a round with a control sets `valid` again.
Marked in the curate pass after round 220.

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
