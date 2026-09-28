---
refines: U-07
paths: [packages/core/rpc_dart/lib/**, packages/transport/*/lib/**]
applies: there is credit accounting released on message delivery
breaks: a wedged connection — a hang.
applied: [206, 207, 208, 212, 213, 228, 229, 230, 231, 281, 282, 366, 445, 469, 475]
status: confirmed (round 445)
---

# RPC-01 — Flow-control credit on the skip path

## Shape

A frame is refused or skipped without becoming a message, while the credit
return hangs on the "message delivered" event.

Round 206 widened this: the frame does not have to be SKIPPED. It is enough that
it is delivered to a consumer that never takes it, because the credit return
hangs on the same event either way. And where there are two levels of
accounting, ask the question once per level — a reclaim at one is not a reclaim
at the other.

## Detector

`_fcOnConsumed` and every one of its callers; every place a frame is dropped
before it becomes a message; `sendMessage` as the sole consumer of credit. Then,
per level: what reclaims credit at teardown, and is the RETURN path gated on a
flag that belongs to the other level?

## Ask

Will the credit the sender has already charged itself ever come back?

## Evidence

An 8 MiB window with 2 MiB per refusal: it wedged on exactly the fourth refusal.
Metadata frames are outside flow control — checked, not assumed (round 162,
off-journal).

Round 206, same detector over the CONNECTION pool, which did not exist in 162.
A 1 MiB pool, a 256 KiB stream window, 256 KiB per call, 12 sequential streams:

    receiver drains the per-stream view    12 calls, 3072 KiB, never wedged
    receiver binds it and never reads       4 calls, 1024 KiB, then dead
    receiver drains, per-stream window OFF  4 calls, 1024 KiB, then dead

1024 KiB is exactly the pool. `_fcForget` reclaimed the per-stream window at
teardown and nothing reclaimed the shared one; and every gate tested
`flowControlWindowBytes` alone, so a pool-only policy metered nothing while
still charging each send. Both fixed; bench `../probes/P-01-connection-window-debt.md`.

Round 207, the same detector one LAYER down — the paths above were widened to
the transports for it. On http2 the pool belongs to package:http2, and rpc_dart
throttles by pausing its subscription, which parks up to a whole connection
window as pending. Ending the stalled call by cancelling drops it uncredited:

    upload,   ended by draining -> the connection recovers
    upload,   ended by cancel   -> every later call HUNG, polled 20 s
    download, ended by resuming -> the connection recovers
    download, ended by cancel   -> every later call HUNG

One cancel is enough (68 KiB, the HTTP/2 default window). Round 208 fixed it by
the owner's choice: never stop reading, keep `flowControlWindowBytes` as the
budget, and FAIL a call past it. All four runs recover, and the bound still
bites at 4171 KiB against 15291 KiB with no bound at all. Bench
`../probes/P-02-http2-aborted-call-pool.md`; lead
`../backlog/archive/B-12-http2-cancel-kills-the-connection.md`.

The lesson that generalises past http2: **a bound implemented by NOT READING is
a bound held in the layer below**, and whatever that layer does with it on
teardown is not yours to control. Prefer a bound you can account for yourself.

The transport packages other than http2 delegate to the core transport, so 206
covers them: `RpcChannelTransport` is the only `IRpcFlowControlled` under
websocket and isolate.

Round 212, the same lens pointed at bookkeeping rather than bytes. Credit state
can outlive the stream it belongs to: `_fcForget` clears the entry at teardown
and a LATE peer grant for that id writes it straight back, where nothing removes
it again. One entry per abandoned upload, linear, zero for drained traffic.
Capped, so not unbounded — the cost is that once the cap fills with dead ids no
new stream is seeded and `initialSendWindowBytes` stops applying.

Round 228 swept the detector properly for the first time — the status had been
`confirmed` with no sha since 213 — and found the branch 206 did not cover.
`_fcForget` repays only when nothing is listening, otherwise deferring to the
consumer's `onCancel`; a consumer that binds and then STOPS satisfies
`hasListener` and never cancels, so neither runs:

    receiver drains                  12 calls, 3072 KiB, never wedged
    receiver never binds a listener  12 calls, 3072 KiB, never wedged
    receiver drains, per-stream OFF  12 calls, 3072 KiB, never wedged
    receiver BINDS and PAUSES         4 calls, 1024 KiB, wedged at call 4

1024 KiB is the pool exactly. Deferred as
`../backlog/archive/B-22-paused-consumer-never-repays-the-pool.md`, because repaying
unconditionally double-credits and the fix has to split the credit paths first;
bench `../probes/P-11-connection-debt-with-a-paused-consumer.md`.

> **A fix that hands responsibility to a callback inherits that callback's
> reachability.** 206 repaid at teardown "unless someone is still listening",
> which is correct only while every listener eventually drains or cancels. The
> branch that does neither is where the same defect came back.

Round 229, the same lens at lead B-05, and rule one found it before any probe.
`_fcNotePeerGranted`'s doc says "a grant frame at all is the proof; its value is
not"; both call sites gated it on `parsed > 0`. So a peer whose first grant was
ZERO was never recorded as participating, the legacy grace expired, and the
level's credit went null:

    peer grants 1     20 KiB accepted    <- control
    peer grants 0    800 KiB accepted    <- 12.5x a 64 KiB window
    peer grants 0     16 KiB accepted    <- fixed: the seeded window, no more

> **The VALUE of a grant and the FACT of one answer different questions.** How
> much may I send, versus does this peer speak flow control at all — and only
> the second may switch the mechanism off. Conflating them made zero, the one
> value that means *stop*, read as *this peer has never heard of stopping*.

Bench `../probes/P-12-zero-grant-reads-as-legacy.md`. Reachable only from a
FOREIGN peer: rpc_dart never sends a zero grant itself, so no bench built from
two rpc_dart transports can see it.

> **Ask the question of the BOOKKEEPING as well as of the bytes.** "Does the
> credit come back?" has a twin: "does the record of it go away?" Both hops
> here — the grant and the forget — had to be instrumented before the order was
> visible, and the first theory was wrong.

Round 445 read the detector's own clause — *"`sendMessage` as the sole consumer
of credit"* — as a question about the OTHER paths, and it is where the lens paid
again. Four send paths can end a stream; only the metered one is metered, so an
ending on any unmetered path had nothing making it wait:

    finishSending          held back    (round 366 gave it the rule)
    sendMetadata(end)      held back    (663cccec, outside the journal)
    sendDirectObject(end)  OVERTAKEN -> held back
    sendMessage(end) fast  0 of 200, and the arm is VOID

`[data:600, direct, end, data:16]` is the failure: the end reached the peer ahead
of a frame the sender was still waiting to place, so the peer counts a stream
short while the sender believes it sent everything. Bench
`../probes/P-99-which-ending-paths-wait-for-a-parked-send.md`; lead B-88 holds
the one path no witness could reach.

> **Being outside the accounting is the qualification, not the exemption.** Each
> round here asked whether charged credit comes back. This one asks the mirror:
> which operations are not charged at all, and therefore pass a gate that exists
> to make things wait. `sendDirectObject` never calls `tryConsume`, which is
> exactly why nothing held it back.

## Round 469 — `credit > 0` rather than FIT makes the window one turn wide

`tryConsume` admits whenever credit is positive, not when the frame fits, and it
never consults `_sendWaiters`. Combine that with `wakeAll()` completing a parked
waiter SYNCHRONOUSLY while the waiter's continuation is a MICROTASK, and the
credit a parked sender was woken for belongs to whoever asks first:

```
                                    fast path took it   parked sender resumed
a fast-path send in the waking turn        true                 FALSE
CONTROL: nobody contends                   false                TRUE
```

> **A gate that admits on a SIGN rather than on a FIT has no queue, and a wake
> is not a handover.** Waking a waiter only lets it re-ask. Anything else that
> asks between the wake and the waiter's turn wins, and nothing in the admission
> path can see that a sender is waiting. The detector is two questions asked
> together: what does the gate compare, and does it know who is queued?

Method note, and it is the one this round paid for:

> **An interleaving one microtask wide is CONSTRUCTED, never raced for.** Round
> 445 attempted this from outside the transport 200 times and every attempt
> re-measured the other branch, because from outside every entry point is async.
> Driving the controller directly is what made the turn addressable — and it is
> also what leaves the transport-level consequence unwitnessed, since the fix
> changes frame order on the wire.

`../rounds/469-the-void-arm-repaired.md`,
`../probes/P-118-the-turn-a-grant-lands.md`.

## Round 475 — the window is one turn wide, so get CALLED inside it

469 measured the window at the controller and declared the transport-level
consequence unreachable: *"from outside `RpcChannelTransport` every entry point
is async"*. 475 closed it six rounds later by noticing what that sentence does
not say.

```
before  [meta, meta, data(64), data(8)+END, data(64)]
after   [meta, meta, data(64), data(64), data(8)+END]
```

> **A caller cannot get inside a callee's turn by calling harder; it gets there
> by being CALLED.** The transport listens to an inbound stream, so a
> `StreamController(sync: true)` runs the whole grant path — `handleInbound`,
> `_onGrant`, `wakeAll()` — before `add` returns, and the woken sender's
> continuation is still a queued microtask. For anything with an inbound stream
> this seam is free and needs no production change.

> **When a round stops on "unreachable", re-check which DIRECTION it measured.**
> 469's sentence was about the API being called and the turn was created by the
> API calling back. Both halves were true; only one was relevant.

The fix's shape is the other thing to carry:

> **A guard on a deliberately synchronous path is conditional, not
> unconditional.** `_claimEnding` is `async`, so `await`ing it always costs a
> microtask hop — on a path whose own comment says it must not introduce one.
> `_parkedSends.containsKey(streamId)` is a map lookup, and the await happens
> only when there is something to wait for. Pinned by a test that runs the same
> sequence with flow control OFF.

`../rounds/475-inside-the-waking-turn.md`,
`../probes/P-119-inside-the-waking-turn.md`.
