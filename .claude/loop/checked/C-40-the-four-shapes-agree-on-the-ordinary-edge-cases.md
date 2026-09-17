---
round: 368
commit: e897128e
paths: [packages/core/rpc_dart/lib/src/rpc/streams/**, packages/core/rpc_dart/lib/src/endpoint/responder_pipeline.dart]
scope: [rpc_dart]
---

# C-40 — the four call shapes agree on four edge cases

Asked of unary, server-stream, client-stream and bidirectional, identically, over
`RpcChannelTransport.pair()` through the endpoint API (P-59). Every row is the
four shapes' answers to ONE question.

```
                    unary        server       client       bidi
ordinary            1 DONE       3 DONE       1 DONE       3 DONE
handler throws
  after emitting 2  0 Rpc        2 Rpc        0 Rpc        2 Rpc
peer transport
  dies mid-call     0 Rpc        10 Rpc       0 Rpc        9 Rpc
consumer cancels    n/a          6 seen       n/a          6 seen
```

`Rpc` is `RpcStatusException`; the number is payloads the consumer received.

**What each row rules out.**

- *Ordinary* — no shape drops or duplicates. The counts are exactly what the
  handler produced.
- *A handler that fails part-way* — the streaming shapes deliver their partial
  output **and then an error**. Neither reports a clean `DONE`, so there is no
  silent truncation: a consumer cannot mistake two of three messages for the
  whole answer. This is the row worth keeping — it is the highest-severity
  outcome the shapes could have got wrong, and they do not.
- *A dead transport mid-call* — every shape settles, none hangs, all four report
  it rather than completing.
- *A consumer that walks away* — both streaming shapes stop; neither leaves the
  handler pumping into nothing within the window.

## Control

**The fifth cell is the control, and it ran in the same process, on the same
rig, in the same pass.** A producer pushing one more request into a cancelled
call reported `uncaught +1` on bidi against `+0` on client-stream — so the
instrument discriminates between the four shapes when they actually differ, and
the four rows above are agreement rather than a bench too blunt to see a gap.
Round 368 fixed that cell; the rows here were unchanged by the fix, measured
before and after.

A second control sits inside the probe itself: a deliberate
`listen((_) async { throw ... })` that must report `+1`, so a `0` anywhere
cannot be "nothing was watching". It reported 1 on both runs.

**What this does NOT cover.** A fifth cell in the same run DID diverge — a
producer pushing one more request into a cancelled call — and is round 368's
finding, not a negative. Deadline parity and status-details parity are covered
separately by `deadline_exception_parity_test.dart` and
`error_details_parity_test.dart`, and were not re-run here.

Measured on the in-process pair, which zeroes out anything made of latency
(P-58's lesson). A cell whose answer depends on a round trip is not settled by
this record.

Re-run when a shape's responder or caller changes how it ends a call, not on a
schedule.
