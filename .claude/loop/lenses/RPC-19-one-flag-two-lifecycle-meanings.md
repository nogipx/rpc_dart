---
refines: U-18
paths: [packages/transport/rpc_dart_http2/lib/**, packages/transport/rpc_dart_websocket/lib/**, packages/transport/rpc_dart_isolate/lib/**, packages/core/rpc_dart/lib/src/resilience/**]
applies: one signal carries both "this is terminal" and "this is recoverable, or local" — a lifecycle flag, an error stream, any single channel two readers interpret differently
breaks: a hang; or every in-flight call answered by something that concerned one of them.
applied: [238, 268, 324, 353, 359, 405, 411, 419]
status: confirmed (round 419)
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

**Round 324 re-swept it over 21 moved files and found the detector's own blind
spot.** The counts hold — `_disconnected` is 14 code lines (a `grep -c` says 15;
one is a comment), and of 11 lifecycle flags in these paths 10 have exactly one
writer and are retired by the rule above. The eleventh,
`RpcClientConnection._isStopped`, has four writers and carries one meaning, with
`_disposed` carrying the terminal one.

Then the ablation that matters: **writing `_isStopped = true` on the give-up
path — this lens's literal defect — changes nothing.** `+120`, every test green,
resume included. `connect()` clears the flag unconditionally, which is the
`_isClosed = false` that `48847ffc` had deleted from http2; keeping it makes
extra writers harmless.

> **A recovery API can be made one-shot by a COUNTER as easily as by a flag, and
> this detector cannot see that.** `maxAttempts` is a budget only because
> `connect()` resets `_reconnectAttempts`. Remove the reset and every later
> `connect()` gives up at once — the exact give-away — while all 119 other
> resilience tests stay green. After listing the writers, ask what else the
> recovery path RESETS.
> `../rounds/324-the-flag-was-never-the-risk.md`,
> pinned by `resume_after_giving_up_test.dart`.

## Round 353 — the object need not be a flag

The three instances above are booleans. The fourth is an ERROR STREAM, and it is
the same shape: `RpcChannelTransport`'s channel subscription carries both *the
connection is gone* and *the peer sent one frame we could not use*, and it reads
both in the first sense — answering every per-stream controller, deliberately,
because *"a connection-level failure is the answer to every call in flight"*.

`RpcWebSocketChannel` sent a plain `RpcException` for a discarded TEXT frame.
Two unary calls parked in a handler, one text frame from the server:

    arm          two in-flight calls
    no text      ok, ok                        connection alive
    text frame   RpcException, RpcException    connection alive   <- before

> **The comment was half true and the suite checked that half.** *"Reported
> rather than fatal, so the connection stays usable"* — and the connection WAS
> usable, in both arms. `non_binary_frame_test.dart` asserts on the channel and
> stops there, so every assertion in it passed while one keepalive from a proxy
> killed every call on the connection. When a comment says "not fatal", ask
> *fatal to what*; the thing it names is rarely the only thing at stake.

The detector extends the same way. For a flag: list the WRITERS and ask whether
they mean the same thing. For a signal: **list what can be put on it and ask
whether the reader's single interpretation is right for each.** Every `addError`
reaching that subscription was enumerated — seven sites across core and five
transports — and exactly one meant something other than "the connection is
gone".

Fixed with `IRpcAdvisoryChannelError`, a marker checked at the one place that
amplifies; the report still reaches `incomingMessages`, where both pipelines log
it, so nothing is dropped. Bench `../probes/P-45-text-frame-blast-radius.md`,
round `../rounds/353-reported-not-fatal-was-half-true.md`.

## Round 359 — the THIRD state, which the flag has no value for

Back on a flag, and the defect is neither of its two meanings. `_disconnected`
on the websocket caller distinguishes "closed for good" from "no connection,
recovery expected" — and `_reconnectOnce` closes `_inner`, then awaits the
factory for a whole handshake, setting the flag only on the OUTCOME:
`false` on success, `true` in the catch. Nothing describes the DURATION.

The bench is a method-by-state matrix, and the two states the code MEANS to have
are the controls:

    method                 healthy     in-window               disconnected
    createStream           id=3        id=3                    StateError
    sendMessage            returned    returned                StateError
    getMessagesForStream   HUNG        RpcStatusException(14)  StateError

> **The in-window column should equal one of the controls, and it equals
> neither.** That is the whole finding, and it is visible only because both
> control columns are in the table. A bench with one control could have read the
> `returned`s as correct.

> **Extend the detector from WRITERS to DURATIONS.** The existing recipe lists
> who writes the flag and asks whether they mean the same thing; here all the
> writers agree and the gap is between them. For every flag on a recovery path,
> ask what it says while the recovery is RUNNING — a flag written from a `catch`
> describes an outcome, and an outcome is not a state.

> **A quiet close is what hides it.** `RpcChannelTransport` answers a closed
> transport with `if (_closed) return;`, so sends into the corpse are accepted
> and dropped and nothing upstream notices — the same quiet-close property this
> lens already records two sections above, biting a second time.

Fixed by one line, `_disconnected = true` immediately after `_inner.close()`.
The GUARD that earns its place is **the window ENDS**: a transport that refused
forever passes both witnesses and is worse than the defect.
`../probes/P-50-calls-inside-the-reconnect-window.md`,
`../rounds/359-the-state-nobody-named.md`.

## Round 405 — list the WRITERS, then ask which endings reach none of them

Round 359 found `_disconnected` written only from the OUTCOME of a reconnect.
Round 405 is the same flag one transport over, and the detector that found it is
mechanical: **enumerate every `_disconnected = true`, then enumerate the ways
the connection can end, and cross them off.**

On the http2 caller there are two writers — the keepalive failure path, and the
catch inside `reconnect()`. `pingInterval` is opt-in. So the ordinary ending —
the server goes away and nobody was pinging — reaches neither, and the flag
stays false forever:

```
transport   health     createStream()   a unary call          isClosed
websocket   degraded   StateError       StateError            false
http2       degraded   no throw         RpcStatusException    false
```

`createStream()` is the decisive row: it calls `_ensureUsable` directly on both,
and on http2 it hands out an id on a dead connection. The websocket sibling sets
the flag from its channel's `onDone` and its comment names exactly this case.

> **A flag whose writers are all on EXCEPTIONAL paths has no value for the
> ordinary one.** Both of http2's are failure handlers — a ping that did not
> come back, a reconnect that threw. Nothing writes it when things simply end.

And the guard the probe needed, which generalises: **gate the arm on the
object's own `health()` before testing what it does.** Without that, "the two
transports behave differently" and "one of them had not noticed yet" are the
same output. `../probes/P-90-which-type-escapes-when-disconnected.md`,
`../rounds/405-the-guard-that-never-fires.md`, B-61.

Imported from private memory in the curate pass after round 234.
