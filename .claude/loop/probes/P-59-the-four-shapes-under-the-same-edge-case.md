---
file: packages/core/rpc_dart/.dart_tool/probe/shape_edge_matrix.dart
round: 368
commit: e897128e
paths: [packages/core/rpc_dart/lib/src/rpc/streams/**, packages/core/rpc_dart/lib/src/endpoint/**]
status: valid
---

# P-59 — the four shapes under the same edge case

## Why it exists

The owner asked for correctness of all four call shapes in ordinary and edge
cases. That is a parity question, and parity cannot be read off one shape: the
instrument has to ask the SAME question of unary, server-stream, client-stream
and bidirectional and put the four answers on one line.

## Measures

Per cell, three things a consumer can tell apart:

- `observed` — how many payloads reached the consumer, counted in the
  application's own `await for` / `listen`, i.e. the far end of the library
- `ending` — the exception type that ended the call, or `DONE` for a clean end
- `uncaught` — errors that reached `Zone.current.handleUncaughtError`, raised
  inside library code (`CallProcessor.send`,
  `RpcChannelTransport.sendMetadata`); the probe's zone handler only counts them

The third is the one with teeth. A clean `DONE` where the handler failed is
silent truncation; an `uncaught` is, in a server process, exit 255.

Cells: an ordinary call; a handler that throws after emitting two; the peer
transport dying mid-call; a consumer cancelling mid-stream; and a producer
pushing one more request into a call that has just been cancelled.

## Control

**Two, and the first is not optional.** The last cell is measured as a count of
errors reaching a zone handler, so a `0` has two readings — nothing was thrown,
or nothing was watching. The probe therefore ends with a deliberate
`listen((_) async { throw ... })`, which must report `+1`. It did, both before
and after round 368's fix, so the fix did not blind the instrument.

**The second is the sibling.** The two request-side rows are the same job
written twice — the library driving a producer the application handed it — and
differ in exactly one thing, whether the send is wrapped. Before the fix:
`ClientStreamCaller.call(Stream)` **+0**, `BidirectionalStreamCaller.requestSink`
**+1**. Nothing else had to be arranged to make the bench discriminate.

Round 368's two canaries are the third: a `rethrow;` in each new catch put the
count back to +1 at each site, each killing only its own witness.

## The numbers (round 368, before the fix)

```
EC0 ordinary        unary  1 DONE | server  3 DONE | client  1 DONE | bidi  3 DONE
EC1 handler throws  unary  0 Rpc  | server  2 Rpc  | client  0 Rpc  | bidi  2 Rpc
EC2 transport dies  unary  0 Rpc  | server 10 Rpc  | client  0 Rpc  | bidi  9 Rpc
EC3 consumer cancels              server  6                          bidi  6
EC4 bidi requestSink       uncaught +1
    client call(Stream)    uncaught +0
CONTROL                    uncaught +1
```

## Trap

The first version of EC4 cancelled the call with `caller.close()`, which closes
the producer's sink too — so the later `add` was API misuse (a synchronous
`StateError` from the controller) rather than the case under test, and it
aborted the run before the remaining cells. The route that leaves the sink open
is the CANCELLATION TOKEN. One rebuild, counted against the round's three.

`RpcChannelTransport.pair()` is adequate here, unlike in P-58: none of these
cells is about latency.
