---
round: 405
verdict: DEFERRED
packages: [rpc_dart_http2, rpc_dart_websocket]
lens: RPC-19
bench: P-90 — new
commit: yes
---

# Round 405 — the guard that never fires

## Target

The drift round 404 recorded and did not file: the same DISCONNECTED state came
back as `StateError` on websocket and `RpcStatusException` on http2, through the
same endpoint API. 404 left it because no caller-visible failure had been
produced from it.

## Hypothesis

It is not a contract split at all but a TIMING artefact — the two transports
notice the disconnection at different moments, so one arm reached
`_ensureUsable` and the other failed earlier on a dead connection. That is the
round-395 and round-399 trap, an arm that never reached the path it names.

## Before

P-90, new, and its design is the answer to that hypothesis: **every arm gates on
the transport's own `health()` first**, polling until it stops reporting
healthy, before making the call that is supposed to hit the guard.

```
transport   health     createStream()   a unary call          isClosed
websocket   degraded   StateError       StateError            false
http2       degraded   no throw         RpcStatusException    false
```

Hypothesis refuted. **Both report `degraded`**, so both reached the state — and
only one guard fires. `createStream()` is the row that settles it: it calls
`_ensureUsable` directly on both transports, and on http2 it hands out an id on
a dead connection.

## Mechanism

`_disconnected` is set in exactly two places on the http2 caller — the
**keepalive** failure path and the catch inside `reconnect()`. There is no
connection-lost path at all. `pingInterval` is opt-in, so on a default http2
caller a server that goes away leaves the flag false forever: the guard never
runs and its prescriptive message is never shown.

The websocket sibling sets it from the channel's `onDone`, and its comment names
this exact case — *"Reached by any server restart or dropped network, with no
reconnect call involved."*

RPC-19, whose shape is a flag with no value for a third state. The third state
here is "the connection died and nobody was pinging".

## After

n/a — deferred.

## Why DEFERRED and not FIXED

Because the round that would fix it has to pick which of the two transports is
right, and **the websocket side's behaviour is a deliberate decision with a
recorded argument**. Its test states it in a table: during a reconnect window a
read used to answer *"a synthetic UNAVAILABLE — which is RETRYABLE, so the
caller is invited to try the thing that cannot work"*, and `StateError` replaced
it on purpose.

That argument transfers. `RpcRetryInterceptor._shouldRetry` retries only
`RpcStatusException` with UNAVAILABLE or RESOURCE_EXHAUSTED and **does not call
`reconnect()`**, so a retry on a disconnected transport spins. Which means
http2's `RpcStatusException` may be the wrong member of the pair rather than the
right one — and I am not the one to decide that across two published transports.

B-61 carries both questions.

> **A round that finds two siblings disagreeing does not automatically know
> which one to move.** RPC-25 has paid eight times by reading the sibling and
> copying it; this is the case where the sibling's choice was itself argued for,
> in a test header, by a round that measured something this one did not.

## Canary

n/a — no fix. The load-bearing control is the `health()` gate, which is what
turned "the transports differ" into "the transports differ for a reason that is
not timing".

## Gate

Not run: no library code changed. The artefacts are two probes, outside analysis
and the suite by design.

## Not fixed

B-61. Also unmeasured and named there: whether `pingInterval` being ON closes
the gap entirely, which the keepalive path suggests but nothing here drove.

## Links

- RPC-19 — the lens; a flag with no value for a third state
- B-61 — the finding, with both owner questions
- P-90 — new; its `health()` gate is the reusable part
- Round 404 — which recorded the drift and said no caller-visible failure had been produced
