---
refines: U-18
paths: [packages/transport/rpc_dart_http2/lib/**, packages/transport/rpc_dart_websocket/lib/**, packages/transport/rpc_dart_isolate/lib/**, packages/core/rpc_dart/lib/src/resilience/**]
applies: one object models both "the caller shut me down" and "the connection is gone"
breaks: a hang.
applied: [238, 268]
status: swept here (round 268, 847d53d2)
---

# RPC-19 — One flag, two lifecycle meanings

## Shape

A single boolean carries two states that are not the same: **terminal** (the
caller closed us; never coming back) and **recoverable** (no live connection,
recovery expected). Every reader then interprets it in whichever sense suits
that call site, and the interpretations contradict each other — one path says
"reconnect required", another refuses the reconnect because the flag means
"closed".

The give-away is a recovery API that works exactly once.

## Detector

Every `bool _closed` / `_isClosed` / `_stopped` in the classes above. For each,
list its WRITERS and ask whether they all mean the same thing: `close()` is
terminal, but a failed reconnect, a dropped socket and a peer death are not.
Then list its READERS — `health()`, the send paths, the post-factory re-check in
`reconnect()` — and ask what each of them wants to know. A flag that four
readers want four different answers from is the defect.

The vocabulary both callers settled on, and what a sweep should expect to find:
`_closed` written ONLY by `close()`, `_disconnected` for "no connection,
recovery expected" (14 occurrences across the two caller transports today).

## Ask

Drive the recovery API **twice, and once while the peer is down.** Does the
second attempt still work?

## Evidence

**`RpcHttp2CallerTransport.reconnect()`, fixed 63aa8e93.** A failed reconnect set
`_isClosed = true` — the same flag `close()` sets. `health()` read it as
"disconnected, reconnect required" (DEGRADED), the send paths read it as "closed"
and threw, and the post-factory re-check read it as "the caller closed us" and
discarded the connection it had just opened. **The transport told you to
reconnect and then refused every attempt.**

> **A previous fix created the fatal combination**, which is the part worth
> keeping: `_isClosed = true` on failure was old, but 48847ffc removed the
> `_isClosed = false` un-close that had been the only way back. Removing an
> un-close is safe only if nothing else sets the flag for a RECOVERABLE reason.
> Check the writers before deleting a state reset.

**The same class on the websocket caller, fixed 3bfa7715.** `reconnect()` closes
`_inner` before calling the factory, so a failed attempt left the wrapper at
`isClosed == false` over a CLOSED inner transport — while `health()`, delegating
to that inner, answered "Transport is closed". The wrapper contradicted itself,
and worse: a call then reached the closed inner transport, whose pipeline raised
`RpcStatusException(14)` from a detached subscription into the ROOT zone and
**killed the isolate**.

> *The quiet-close property is the trap.* `RpcChannelTransport` answers a closed
> transport SILENTLY — `sendMetadata` is a no-op, `getMessagesForStream` returns
> an empty stream — so nothing throws to tell a wrapper it is delegating into a
> corpse. A wrapper must never hand work to one.

**Never `finish()` a dead http2 connection; always `terminate()`.** The reconnect
prologue awaited `_connection.finish()` on the connection it was replacing — and
reconnect runs precisely when that one is gone. finish() writes a GOAWAY, and
writing to a closed frame writer gives `Bad state: Cannot add event after
closing`, thrown asynchronously from a subscription package:http2 created in the
ROOT zone: the surrounding try/catch never sees it and it kills the isolate.
Reproduce by calling `reconnect()` twice. `_discardConnection()` terminates
inside `runZonedGuarded` and exists for this. Shared with
`RPC-16-check-before-await.md`.

> **The testing lesson, and it is why this lens exists at all:** the suites
> called `reconnect()` ONCE per test, on a healthy peer. Calling it twice, and
> once while the peer was DOWN, exposed all three defects. A one-shot happy-path
> test of a recovery API proves nothing. See
> `../lessons/L-08-a-per-test-connection-hides-it.md`.

**Round 238 swept it: no third instance.** Every lifecycle flag in these paths
either belongs to an object with no recovery path — so there are not two
meanings to conflate — or already carries the split. And the behavioural half,
four failed reconnects into a dead peer then recovery then a real call, twice
over, came back clean on the websocket caller.

> **A flag conflates two meanings only where two meanings exist.** The static
> sweep is therefore cheap: list the writers, and if `close()` is the only one,
> stop. The classes worth the behavioural battery are exactly those with a
> recovery API.

Bench `../probes/P-17-retry-until-the-peer-returns.md`, whose ablation is what
makes that CLEAN mean anything — and which took two attempts to aim: removing
the `_disconnected` branch from `health()` moved nothing, because the bench
reads what `reconnect()` returns. **Ablate the observable the bench samples.**

Imported from private memory in the curate pass after round 234.
