---
refines: U-18
paths: [packages/transport/rpc_dart_http2/lib/**, packages/transport/rpc_dart_websocket/lib/**, packages/transport/rpc_dart_isolate/lib/**, packages/core/rpc_dart/lib/src/resilience/**, packages/core/rpc_dart/lib/src/rpc/transports/**]
applies: one signal carries both "this is terminal" and "this is recoverable, or local" — a lifecycle flag, an error stream, any single channel two readers interpret differently
breaks: a hang; or every in-flight call answered by something that concerned one of them.
applied: [238, 268, 324, 353, 359, 405, 411, 419, 421, 485, 486, 495, 531, 552, 572, 592, 651, 653, 667, 668, 669, 676]
status: confirmed (round 592)
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

## Round 667 — the signal has more than one reader

353 enumerated the WRITERS of one subscription (the channel's) and fixed its
reader. `incomingMessages` is a second signal with three readers that act
connection-wide -- the responder pipeline, the unary responder, and
`RpcClientConnection` -- and three transports wrote one-stream errors to it
un-marked: a malformed http2 frame failed three innocent calls `[13,13,13]`, a
request over the channel policy `[3,3,3]`, one server RST through
`RpcClientConnection` `[14,14,14]`. Enumerate writers AND readers, per signal.
`../rounds/667-one-stream-error-fails-every-call.md`.

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

## Round 485 — the signal need not belong to us at all

Round 353 moved this lens from a flag to an error stream. Round 485 moves it one
level further, onto a **status code on the wire** — and the reader is not a
transport but core's `RpcRetryInterceptor`.

`UNAVAILABLE` is the framework's "the connection is gone". It is ALSO what a
handler throws when its own downstream is down, what a draining server answers,
and what core synthesises for a stream that ended without a status.
`_reconnectIfConnectionIsGone` read it in the first sense only and called
`transport.reconnect()` — which on a websocket closes the live socket under
every OTHER call:

    B's handler throws     sockets   A (a server stream on the same socket)
    unavailable               2      errored after 4 messages
    resourceExhausted         1      alive, 30 messages

> **Ask the component about itself.** The status describes the CALL; only the
> transport can describe the CONNECTION, and every transport here already
> answers it — `health()` reports degraded on a websocket whose socket dropped
> and on an http2 connection whose peer went away. One gate, `isHealthy`, and
> the two meanings stop being one signal.

> **The detector does not extend to "list the writers" here, because the writers
> are the peer and the application.** For a signal that arrives from OUTSIDE,
> enumerate who can PRODUCE it, then ask whether the reader's single
> interpretation is right for each. Seven `addError` sites in round 353; four
> producers of UNAVAILABLE here, and only one of them was about the connection.

The blast radius is the give-away, and it compounds: every collateral failure is
itself UNAVAILABLE, so N concurrent retrying calls feed the same mechanism.

A caution this round paid for in a gate failure: the capability the reconnect
exists for is real, and the fix must not quietly revert it. The bench's third arm
drives a path that really died and reads `sockets=2, recovered` — with the
reconnect ablated, `sockets=1, RpcNoConnectionException`.
`../probes/P-124-what-one-calls-unavailable-costs-the-others.md`,
`../rounds/485-unavailable-is-about-the-call.md`, B-94.

## Round 486 — check the reader ABOVE the one you fixed

Round 353 split one signal into "the connection is gone" and "one frame was
bad", and taught `RpcChannelTransport` the difference. Round 486 is the same
signal read by `RpcClientConnection`, which sits one layer above and had no such
split: `cancelOnError: true` and retire on any error.

    event                        transports built   the other call
    a TEXT keepalive                  1 -> 2        errored at 3 messages
    a lenient policy violation        1 -> 2        errored at 3 messages
    nothing sent (control)            1 -> 1        alive at 88

> **A distinction is only as good as its furthest reader.** 353's marker worked
> exactly as designed at the layer it was written for, and the doc that states
> the contract — *"reaches `incomingMessages`, where both endpoints log it. It
> just stops there"* — was false one object up. When a round teaches one layer
> to tell two things apart, enumerate everyone else who reads that signal.

**And the discriminator is not the TYPE.** Arms 2 and 4 of the bench send the
identical `RpcFrameException.policy` and differ only in `closeOnProtocolError`:
strict mode closes the transport, and that close arrives as `onDone`, which
retires. One type, two outcomes.

> **Let the thing speak for itself.** The fix does not classify the error as
> fatal or not; it declines to act on errors at all for these kinds and lets the
> connection's own ENDING be the signal. The same move as round 485 asking
> `health()` instead of reading a status — and the reason both work is that the
> object under discussion is the only one that knows.

The second canary is what makes the pair complete, and it fails on a different
test from the first: restoring `cancelOnError: true` leaves the witnesses green
and kills the STRICT guard, because a subscription cancelled by the error it
declined to act on never sees the close.
`../probes/P-125-what-one-bad-frame-costs-a-reconnecting-client.md`,
`../rounds/486-a-bad-frame-is-not-a-dropped-connection.md`, B-95.

## Round 495 — a DURATION has segments, and a fix can cover one of them

Round 359 asked this lens's duration question of `_disconnected` and found the
flag describing an outcome rather than a state. It moved the flag up to cover the
factory handshake. Round 495 is the same flag, the same method, and the two
awaits AHEAD of where 359 put it:

    inside the CLOSE await     RpcClosedException, 9, not retryable   health=closed
    inside the FACTORY await   RpcNoConnection,   14, RETRYABLE       health=degraded
    no reconnect in flight     no throw                               health=healthy

> **"During the recovery" is not one instant, and a fix that covers the await it
> was written for leaves the others.** The detector that finds this is the same
> one 359 used, applied per AWAIT rather than per method: for every suspension
> point between the flag's last write and the state being restored, ask what the
> flag says there. Here there were three and the fix had covered one.

> **Make the segments separately addressable in the bench.** Each arm holds ONE
> await open — a fake channel whose close is slow for the first, a slow factory
> for the second — so the arms differ in which suspension point the call lands
> in and in nothing else. The already-fixed segment is then the control, and it
> is what says the bench can read the right answer.

And `health()` carried a second finding the lead never named: it read CLOSED,
terminal, because it delegates to an inner transport that is already closed. **Ask
what the OBSERVERS of a state report during it, not only what the callers get** —
a supervisor polling health during a recovery was told the transport was gone for
good, which is this lens's original defect wearing its original clothes.

A trap worth inheriting: the fake's stream must stay OPEN. `Stream.empty()` ends
at once, so the transport's own `onDone` treats the peer as dropped at
construction and sets the flag for a reason unrelated to the window — every arm
then reads alike and nothing can be told apart.

`../probes/P-133-which-part-of-reconnect-answers-what.md`,
`../rounds/495-the-whole-method-is-one-window.md`, B-104.

**Round 531 — the flag can be flipped BACK inside the window.** `RpcWebSocketServer`'s
`_isRunning` means both "accept connections" and "no shutdown is in progress", and
`stop()` clears it before doing any of its work. A `start()` in that gap set it again
and returned, while the stop carried on from where it was — so the restarted server's
new connections belonged to the old shutdown:

    fresh arrives during the drain    torn down, server reports running
    fresh arrives during the close    never closed, and held by NOTHING
    CONTROL after the stop            held
    CONTROL no stop at all            held

`../probes/P-164-what-happens-to-a-connection-accepted-mid-shutdown.md`, B-135.

> **A conflated flag has two failure modes, not one, and they need separate arms.**
> The two shutdown phases wreck a connection differently — closed by the wrong owner,
> and forgotten entirely — so one "did it break" arm describes neither. Read the KIND
> of ending, not a boolean: refused, torn down, and never are three states a `bool`
> collapses to two.

> **A phase that ends early is a phase the rig never entered.** The drain arm had no
> in-flight call, so the drain returned on its first poll and the arm became a
> duplicate of the next one — two identical rows, which read as a consistent finding
> rather than as a broken rig. Same family as the `Stream.empty()` trap above: when
> two arms agree suspiciously, check whether one of them ran.

> **The fix may already exist one layer down.** "Refuse start while stopping" was
> unnecessary here: `_handleConnection` already refuses and ANSWERS a peer while the
> flag is false, so serialising `start()` behind the stop was enough. Look for the
> guard before adding one.

## Round 552 — the flag was a DIRECTION, and the conflation switched a limit off

An inbound end-of-stream meant both "the peer has finished sending" and "the call is over".
For a stream this side opened those coincide — the inbound end IS the response's last frame.
For one the PEER opened they do not, and a server stream half-closes its request immediately,
so the end of the call was declared at the start of its response phase.

```
the window held at 64 KiB, only initialSendWindowBytes moving
  initial off      510806 msgs   sendCredit: 0  advertised: 0
  initial 4 KiB      4372 msgs   sendCredit: 1  advertised: 1
after:  every row 4372           sendCredit: 1  advertised: 1
```

> **A flag that conflates two LIFECYCLE meanings is the usual shape; this one conflated
> two DIRECTIONS.** "Finished" is per-direction on anything duplex, and a single
> end-of-stream signal has no room for that. The discriminator was already computed four
> lines above the defect — `locallyInitiated`, used for something else — which is the
> tell worth remembering: when a site needs to know which side owns a thing, look for
> code nearby that already asked.

> **The conflation was invisible because a SEPARATE mechanism kept re-creating the state
> it destroyed.** `tryConsume` re-seeds credit from `initialSendWindowBytes` whenever the
> entry is missing, so at the defaults the window worked and nothing was observable. Turn
> that unrelated field off — a documented, legal configuration — and the per-stream window
> was off for the whole connection. **A limit that is restored by accident is a limit with
> no test**, and the way in was to vary the field that was doing the restoring, not the
> one under test.

> **Fixing one direction's cleanup deletes the other direction's.** The first version
> gated the whole block and removed the connection-pool repayment round 206 added — caught
> by its test, with the number (`sender wedged at call 4 after 1024 KiB`). When a cleanup
> site serves two concerns, split it by concern: the inbound half really is over and really
> does owe the pool.

`../rounds/552-the-window-was-off-not-loose.md`,
`../probes/P-180-what-the-window-actually-charges.md`, B-195, B-218.

Imported from private memory in the curate pass after round 234.

## Round 592 — the signal was a MAP, and one key was missing from two answers

Round 353 widened this lens past flags: the object can be an error stream. 592
widens it once more — the object is a `Map`, and the two meanings are "this key is
present" and "this key is not".

`RpcWebSocketCallerTransport.health()` assembles `details` from the inner health
plus two counters only the wrapper can see. Two early returns above it answer
without them:

```
_closed        closed(...)                              no details at all
_disconnected  degraded(details: {"supported": true})     no counters
```

> **For a map-shaped signal, the detector is not "who writes it" but WHICH KEYS
> each exit carries.** List the returns of the accessor, then list the keys each
> one sets, and read the table. Both early returns here had good documented
> reasons — a closed transport must not delegate, an inner closed mid-reconnect
> contradicts the wrapper — and neither reason mentions the counters, so they were
> dropped by omission rather than by decision.

> **And the exits that omit are the states a diagnostic exists FOR.** A supervisor
> polls `health()` to find out what is wrong, so a key that disappears on the
> closed and disconnected answers is absent at exactly the moment it is read. That
> is what turned a missing counter into `Null check operator used on a null value`
> in a gate run, three seconds after the same call returned 0.

`../rounds/592-the-diagnostic-that-went-quiet-when-it-mattered.md`, B-219, B-104.
