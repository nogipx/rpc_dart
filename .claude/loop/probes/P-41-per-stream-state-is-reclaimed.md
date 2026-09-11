---
file: packages/transport/rpc_dart_http2/.dart_tool/probe/per_stream_state_is_reclaimed.dart
round: 343 — the validating round
commit: 4527416a
paths: [packages/transport/rpc_dart_http2/lib/**]
status: valid
---

# P-41 — does per-stream state come back to zero

Runs N completed unary calls on ONE connection and reads the transports' own
`health()` details before and after. The counts it prints —
`incomingStreams`, `streamSubscriptions`, `streamParsers` — are published by the
library, not invented by the probe, so nothing has to be instrumented.

One connection, not one per call: a per-call connection cannot see per-connection
accumulation (L-08).

## Measures

Per-stream collection sizes after every call that created them has completed.
Anything non-zero is state the connection will carry until it dies.

## Control

Remove the prune and the count must climb. **Both prunes** —
`_streamParsers` is removed in `_handleIncomingStream`'s `onDone` AND in
`releaseStreamId`, and either alone is sufficient:

```
                                          after 1    after 2001
as shipped                                0          0
releaseStreamId's remove deleted          0          0      <-- masked
BOTH removes deleted                      1          2001
```

**The first ablation is the one to learn from.** It changed nothing, which reads
exactly like "the bench cannot see a leak" — and would have made this round's
CLEAN worthless. The redundancy is deliberate belt-and-braces in the transport,
and it masks a single-site ablation completely (L-01).
