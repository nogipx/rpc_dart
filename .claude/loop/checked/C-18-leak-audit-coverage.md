---
round: off-journal 191
commit: 5bf4d34e
paths: [packages/core/rpc_dart/lib/**, packages/transport/rpc_dart_websocket/lib/**, packages/transport/rpc_dart_http2/lib/**, packages/transport/rpc_dart_isolate/lib/**, packages/transport/rpc_dart_http/lib/**]
scope: [the whole repository]
---

# C-18 — The full leak audit

A deliberate full leak re-audit of `packages/core/rpc_dart`, run over two rounds
in September 2026, off-journal. Numbers imported from private memory after round
238, where this record had been a four-line stub.

Counters compared against a **post-warm-up baseline**: transport
`activeStreams` / `streamControllers` / `finishedStreams`; responder
`activeResponders` / `metadataStreams` / `bufferedMessages` /
`clientStreamBuffers`; caller `trackedMethods` / `pendingRequests`.

**Found, and fixed at 250455ae:** `_finishedStreams` retained one id per
deadline-aborted or cancelled call. Teardown prunes it at the 2 s reclaim grace,
then the late trailer of a handler that outlived its deadline re-adds it and
nothing removes it again. **3000 aborted calls grew the set to 2996**; capped at
1024 now. Only `unary deadline` and `unary cancelled` drifted, on both
transports.

**Swept clean — do NOT re-run these dimensions:**

- **Sequential matrix, 38 cases**: unary / server-stream / client-stream / bidi
  x frame + direct transports x ok / abandoned / handler-throws /
  unknown-method / deadline / cancelled / request-stream-errors, 15 iterations
  each. Plus the TRUE zero-copy path (no codecs) for every shape.
- **Concurrency**: 180 concurrent unary (success and throwing), 120 concurrent
  for each of server-stream drained, server-stream `take(1)`, client-stream and
  bidi. A cleanup race would show here and does not.
- `RpcPeerEndpoint`, both directions on one connection, 20 rounds.
- **Reconnect churn**: 30 forced reconnects, 31 transports made, exactly 1 left
  open (the live one), 0 after `dispose()`.
- Interceptor chain: retry + circuit breaker in front of every call, including a
  retried UNAVAILABLE.
- Transport death with 30 server streams in flight: the server released
  everything.

> **A concurrency test does not subsume a sequential one.** 600 CONCURRENT
> deadline aborts pushed `finishedStreams` to only 34, far under the cap,
> because the leaking ORDER — teardown, then the late trailer — is much rarer
> under concurrency. The sequential matrix is what exposed it.

> **Method: wait out the responder's 2 s `_reclaimGrace` before sampling**, or
> work still legitimately in flight reads as a leak. That produced a false
> positive in an earlier round.

## Control

The defect found in that same audit: the leak is visible on the same counters,
so they are demonstrably able to show one. `finishedStreams` 2996 against a
baseline of ~0 is the number that says the instrument works.
