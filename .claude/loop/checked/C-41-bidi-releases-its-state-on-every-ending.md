---
round: 372
commit: 21f3525c
paths: [packages/core/rpc_dart/lib/src/endpoint/responder_pipeline.dart, packages/core/rpc_dart/lib/src/rpc/streams/bidirectional/**, packages/core/rpc_dart/lib/src/rpc/transports/flow_controller.dart]
scope: [rpc_dart]
---

# C-41 — a bidi call releases its state on every ending

Seven ways of ending a bidirectional call, three scales, one connection
throughout (P-63). Every cell is the residue AFTER the call settled.

```
ending             5 calls  20 calls  60 calls
unary (control)       0         0         0
normal                0         0         0
consumerCancel        0         0         0
tokenCancel           0         0         0
handlerThrows         0         0         0
deadline              0         0         0
neverFinish           0         0         0
```

Zero on all eleven counters: `openStreams`, `activeResponders`, live handlers,
transport `activeStreams` / `streamControllers` / `statusSeen`, and flow
control's `sendCredit` / `deferred` / `owedConn` on BOTH sides.

`neverFinish` is the one worth naming: a caller that never half-closes and simply
walks away from its subscription leaves nothing behind — the case that, for
client-stream, round 368's own notes describe as parking a responder forever.

## Control

**Every cell is zero, so the negative rests entirely on the ablation.** Removing
the bidi responder's cleanup makes the same counters climb linearly with the
call count — 5 / 25 / 85 on `openStreams`, `activeResponders` and
`sendCredit` — so the probe sees this class of leak at these scales. Restored,
`git diff --stat` empty, re-measured back to zero.

A second control rides along: the unary arm shares the connection, the endpoints
and the run.

## What it does NOT cover

- RSS, and anything no counter names. A retained closure that no map keys would
  not appear here.
- Endings made of latency. `RpcChannelTransport.pair()` flattens those (P-58).
- The endpoint's own bidi pump beyond what these counters see; round 371 named
  `_pumpBidirectionalResponses` as a third implementation whose back-pressure is
  unmeasured.
- Duplex SEMANTICS — whether the two directions behave independently. That is a
  different question and not settled here.

Re-run when a bidi teardown path changes, not on a schedule.
