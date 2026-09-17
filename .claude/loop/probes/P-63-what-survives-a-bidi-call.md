---
file: packages/core/rpc_dart/.dart_tool/probe/bidi_leak_matrix.dart
round: 372
commit: 21f3525c
paths: [packages/core/rpc_dart/lib/src/endpoint/responder_pipeline.dart, packages/core/rpc_dart/lib/src/rpc/streams/bidirectional/**, packages/core/rpc_dart/lib/src/rpc/transports/channel_transport.dart, packages/core/rpc_dart/lib/src/rpc/transports/flow_controller.dart]
status: valid
---

# P-63 — what survives a bidi call, per way of ending it

## Why it exists

The owner asked for a hard look at the bidirectional shape — bugs, leaks,
correct handling. Bidi is the only shape with two independent directions, so it
has the most ways to end, and a leak shows up per ENDING rather than per call.

## Measures

Eleven counters, all read **after** the call has settled, at three scales on ONE
connection (L-08: a per-call connection cannot see a per-connection leak):

- pipeline: `openStreams`, `activeResponders`
- the handler's own live count, incremented on entry and decremented in a
  `finally`
- transport: `activeStreams`, `streamControllers`, `statusSeen`
- flow control, both sides: `sendCredit`, `deferred`, `owedConn`

Seven endings: an ordinary call, a consumer cancelling its subscription, a
cancellation token, a handler that throws, a deadline, a caller that never
half-closes, and — as the **control shape** — unary through the same endpoints in
the same run.

Three scales (5, 20, 60) because a single number cannot tell retention from
churn (measurement.md item 7): a count that tracks the call count is retention,
one that returns to zero is churn.

## Control

**A zero is suspicious** (measurement.md item 8), and every cell here is zero, so
the probe is worth nothing without showing it can report otherwise.

Ablation: the bidi responder's cleanup — `_detached(responder.done.whenComplete(
() => _cleanupStream(streamId)))` in `_ensureBidirectionalResponder`, both
branches — replaced with `Future<void>.value()`. The counters then climb
linearly with the call count:

```
                 openStreams  responders  fcSrv.sendCredit
after  5 calls        5           5             5
after 20 calls       25          25            25
after 60 calls       85          85            85
```

So the instrument sees this class of leak, at this scale, on these counters. The
tree was restored and `git diff --stat` verified empty before the verdict.

The second control is the unary arm, which shares the connection, the endpoints
and the run.

## The numbers (round 372)

Every counter, every ending, every scale: **0**. Table in
`../checked/C-41-bidi-releases-its-state-on-every-ending.md`.

## What it establishes, and what it does not

Establishes: no state is retained per bidi call under any of the seven endings,
on the counters listed.

Does not establish anything about RSS or about objects no counter names — a
retained closure that no map keys would not appear here. Nor about latency-shaped
endings: `RpcChannelTransport.pair()` flattens those (P-58's lesson).
