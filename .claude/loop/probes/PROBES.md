# Benches

What a bench is and when it counts as valid — [../LOOP.md](../LOOP.md). The
record format — `../../skills/improvement-loop/specs/probe.md`.

Rounds 201-205 worked with one-off probes: bench registration appeared in the
skill after them, so nothing before 206 has a record here.

**`stale (sha)` does not mean broken.** It means the code under the bench's
paths has moved since its control was last run, so the next round to reuse it
repeats that control FIRST. Only a round with a control sets `valid` again.
Marked in the curate pass after round 220.

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
