---
round: 414
verdict: FIXED
packages: [rpc_dart, rpc_dart_websocket, rpc_dart_http2]
lens: RPC-08
bench: P-88 — reused
commit: yes
---

# Round 414 — two decisions carried out

## Target

Two owner decisions, recorded and then executed. `loop.py status` lists these
first for a reason: a decision that sits unexecuted is the loop holding an
answer it asked for.

- **B-60** — add `markDraining()` and call it from the websocket drain
- **B-61** — teach `RpcRetryInterceptor` to call `reconnect()`

## Hypothesis

Both are mechanical: one new method and one new call. Executing a decision is
transcription.

It is not — L-13's shape twice over. B-60's method could not live where it was
first written, and B-61's fix made a test fail because that test had been
measuring the very hollowness the decision was taken to remove.

## Before

P-88 reused, eight parked server-streams holding the in-flight count above zero
so both transports spend their whole budget and ADMISSION is the only variable:

```
                served after stop began   refused after
websocket                 1347                  3
http2 (GOAWAY)               4                540
```

And `RpcRetryInterceptor` retried UNAVAILABLE without ever calling
`reconnect()`, so on a bare transport every attempt returned to the same dead
connection.

## Mechanism

Both mechanisms already existed and were unreachable from where they were
needed. `_respIsDraining` rejects new streams and only `drain()` could set it —
alongside cancelling every active context. `reconnect()` is on `IRpcTransport`
and nothing in the retry path called it.

## After

```
                served after stop began   refused after
websocket                    3                 472
http2 (GOAWAY)               4                 540
```

and a drained http2 connection recovers on the second attempt instead of
spending three on the same corpse.

## B-60 — the drain now stops admitting

```
                served after stop began   refused after
websocket before          1347                  3
websocket after              3                472
http2 (GOAWAY)               4                540
```

The two transports agree now. The refusals are the other half of the reading:
those calls are ANSWERED UNAVAILABLE rather than dropped, which is what a
draining server owes a caller.

**The mechanism was already in core and unreachable.**
`responder_pipeline.dart:592` answers a new stream UNAVAILABLE while
`_respIsDraining` is set; the only public route to that flag was `drain()`,
which also cancels every active context — the opposite of what
`stop(drainTimeout:)` promises.

### Where the method had to live, which was not where I first put it

Declared on the mixin first. That does not compile at the call site:
`RpcWebSocketServer._endpoints` is `List<RpcEndpointBase>` deliberately, because
peer-mode endpoints serve calls too and narrowing the list drops them — and
`RpcResponderPipelineMixin` is HIDDEN from the public surface by round 291's
RPC-24 work, which was measured, so a transport package cannot even type-test
against it.

So `markDraining()` is declared on `RpcEndpointBase` as a no-op and overridden
in the mixin — the same shape `collectEndpointMetrics()` already uses, and for
the same reason. The default is honest rather than defensive: an endpoint with
no responder half has nothing to stop admitting.

## B-61 — the retry now reconnects

The interceptor retried UNAVAILABLE and never called `reconnect()`, so on a bare
transport every attempt went back to the SAME dead connection: the budget burned
and no attempt could pass. A retry that cannot succeed is worse than none — it
spends the caller's deadline to arrive at the same failure.

`_reconnectIfConnectionIsGone` runs after the backoff, for UNAVAILABLE only.
RESOURCE_EXHAUSTED means the peer is overloaded and its connection is fine;
reconnecting would drop a working one and add load to a server asking for less.

Best-effort by construction: a transport that cannot reconnect ANSWERS rather
than throwing — `RpcChannelTransport` returns `degraded / supported: false` —
and a failed attempt leaves a recoverable transport, so the next attempt is
still worth making.

### The test that failed was measuring the hollow version

`a drained connection is retried as the retry doc promises` went `3 -> 2`
attempts. Its `drain()` sends GOAWAY on ONE connection and leaves the listener
up — the canonical load-balancer case — so a retry that reconnects now
**recovers on the second attempt**.

Counting three failures was a proxy for "a retry happened", and the proxy was
only meaningful while no attempt could pass. Re-pointed at the stronger
property: the call succeeds. Keeping `== 3` would have pinned the hollow
promise this round exists to make real.

## Canary

- `the_drain_stops_admitting_test.dart` — the witness is `served < 50` against
  1347, and its GUARD is `refused > 0`, because a drain that silently DROPPED
  those calls would also score a low `served`.
- `retry_reconnects_before_trying_again_test.dart` — three tests, two of them
  guards: RESOURCE_EXHAUSTED is retried WITHOUT reconnecting, and a
  non-transient error does neither. Without those, "reconnect on every retry"
  would pass the witness.

## Gate

`melos run analyze` clean over 21 packages + wasm; `format:check` clean;
`license:check` compliant; workspace suite **SUCCESS in all 14 packages**.

## Not fixed

B-58 and B-59 are still the owner's. B-59 is adjacent to this round — it is the
same server's shutdown — and narrower now that the drain refuses rather than
serves, but the gap it names is between `stop()` and `start()`, which
`markDraining` does not touch.

## Links

- B-60, B-61 — both closed here
- P-88 — reused; the arm that made it valid is round 403's parked streams
- RPC-08 — a capability present on one transport and unreachable on its neighbour
