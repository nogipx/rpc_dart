---
status: awaiting owner — premise corrected in round 406; the type is unified, the behaviour is not
round: 405
commit: 866623d3
paths: [packages/transport/rpc_dart_http2/lib/src/transports/http2/rpc_http2_caller_transport.dart, packages/transport/rpc_dart_websocket/lib/src/websocket_caller_transport.dart]
probe: packages/transport/rpc_dart_http2/.dart_tool/probe/which_type_escapes_when_disconnected.dart, with the websocket half in that package's copy
reason: owner decision — two tested, deliberate contracts disagree about whether a dead connection is worth RETRYING, and unifying the behaviour means overturning one of them
---

# B-61 — the two transports disagree about a dead connection

> **Round 406 corrected this lead's premise.** It was filed as "the http2
> caller never notices it is disconnected", which read as a gap. It is not one.
> http2 notices and deliberately answers **UNAVAILABLE and retryable**;
> websocket deliberately refuses **non-retryably**. Two rounds, two defensible
> choices, each pinned by a test that states its argument. The guard's
> unreachability on http2 is the visible edge of that disagreement, not a bug.

## What round 406 shipped

The TYPE, which the owner chose: both `_ensureUsable` implementations now throw
`RpcStatusException(RpcStatus.failedPrecondition, ...)` instead of one throwing
`StateError`. One `catch` now covers every transport, and FAILED_PRECONDITION is
not retried — `RpcRetryInterceptor._shouldRetry` takes only UNAVAILABLE and
RESOURCE_EXHAUSTED — so the earlier round's argument survives the type change.

## What it could not ship, and why

Making the http2 guard fire on a dead connection broke two tests, both
deliberate:

```
test                                                   asserts
goaway_is_unavailable_test:
  "a drained connection is retried as the retry         UNAVAILABLE, RETRYABLE
   doc promises"
max_concurrent_streams_saturation_test:
  "GUARD: a genuinely dead connection still reports     createStream() SUCCEEDS,
   UNAVAILABLE and down"                                then UNAVAILABLE
```

The second is exactly the ending this lead named — an abruptly killed socket —
and it requires `createStream()` to hand out an id and the send to answer
UNAVAILABLE. Reverted.

A first attempt was worse and is worth not repeating: it dropped the GOAWAY
exemption from the predicate, on the reasoning that a drained connection with
nothing in flight is simply gone. health()'s three branches distinguish cases
for the MESSAGE, not for liveness, and one of them is load-bearing for retry
semantics.

## Owner decision

Which retry semantics win for a connection that is gone?

```
option                          consequence
UNAVAILABLE, retryable          http2's current behaviour everywhere. A retry
  (gRPC semantics)              can succeed through a pool or a reconnecting
                                proxy — but rpc_dart's own retry interceptor
                                does not call reconnect(), so on a bare
                                transport every attempt hits the same dead
                                connection and the budget is burned.
FAILED_PRECONDITION,            websocket's current behaviour everywhere. Fails
  not retried                   fast and names the remedy; loses the retry that
                                CAN work behind a pool.
retry learns to reconnect()     resolves the conflict instead of picking a side,
                                and is the largest of the three: it changes
                                RpcRetryInterceptor, not a transport.
```

The third is the only one that makes UNAVAILABLE honest on a bare transport, and
it is a core change rather than a transport one.
