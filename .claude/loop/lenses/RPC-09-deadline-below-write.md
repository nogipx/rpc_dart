---
refines: U-16
paths: [packages/core/rpc_dart/lib/**, packages/transport/rpc_dart_http/lib/**]
applies: the client writes the request and awaits the reply on one channel
breaks: a hang that never ends.
applied: [210, 221, 244, 322, 434, 693, 717, 726, 743, 751, 758]
status: swept here (round 758, a0a78cac)
rank: 20
---

# RPC-09 — A call deadline that sits below the write

## Shape

The client writes the request and waits for the reply in sequence, while a
server that refused on size stops reading.

## Detector

Places where an `await` on the send precedes waiting for the reply; deadlines
guarding a completer the code may never reach.

## Ask

Does the deadline fire at all? If not, what blocks earlier?

## Evidence

The send parked in the flow-control window while the refusal sat unread in the
same stream (round 168, off-journal).

Round 210 swept it and the shape does not arise on the current code, for a
structural reason worth keeping: **the caller's call future resolves on the
RESPONSE path, which is independent of the request pump.** Measured on both
halves, each against a draining-handler control:

    http2, server refuses a stalled upload   status 8 in 0.2 s, 1038 pulled
    core, handler answers with the client
      PARKED at the window (17 msgs, 68 KiB
      against 64 KiB), 0 consumed            completed in 0.4 s

**Round 244 re-swept it over six moved files, including the two that rounds 240
and 242 edited.** One parking site (`_fcAwaitCredit`), three wake paths — credit,
the legacy grace timer, `close()` — and all three intact; `close()` walks
`_fcSendWaiters` before it touches anything else, and round 240's
`_idManager.releaseAll()` lands twelve lines later without reaching them.

> **The round opened meaning to attack round 240's own buffering and found the
> fix SMALLER than what it replaced.** A plain broadcast dropped everything that
> arrived unlistened; the buffered one drops only past its bound. "Attack your
> own fix" is worth doing precisely because the answer is sometimes that the
> hazard shrank — one comparison to check, a whole round to assume.

An ablation removing `_fcWake` from `_fcForget` moved neither number, which both
confirms the independence and shows THAT ablation could not see a hang — so the
probes were not promoted to benches in 210. What it left open is a parked sender
outliving its own call, which is a leaked completer rather than a hang:
`../backlog/B-13-parked-sender-outlives-its-call.md`.

> **When a sweep comes back clean, ask what the ablation proved was UNTESTED.**
> Here it was the very wake a previous round added for this purpose.

Round 221 re-measured, because round 212 gated `_fcOnGrant` on the stream still
being tracked — a new way for a grant to be refused, and therefore a new way for
a parked sender to hang. Both halves reproduce. And the ablation 210 was missing
turned up by aiming at the CREDIT path instead of the wake:

    _fcOnGrant refusing every grant:
      handler drains (healthy)   HUNG, 20 s, 16 pulled
      handler answers early      completed, 0.4 s

> **Aim the ablation at the mechanism the CLAIM depends on.** 210 ablated the
> wake, which the claim does not rest on, and concluded its rig was blind. It
> was not: starving the credit path hangs the draining call while the answered
> call still returns in 0.4 s — which is the independence claim, demonstrated
> rather than argued. Bench `../probes/P-10-parked-sender-learns.md`.

**Round 322 re-ran that ablation over 34 moved files and all eight cells of
P-10's table are unchanged from 221.** The bounded inbound queue added since
(`BufferedBroadcastController`) does not extend this lens's surface: it enqueues
only while no listener is attached, and its overflow is fatal-with-error rather
than silent, so it cannot produce `a hang that never ends`.

> **The wake-path COUNT is part of the detector, and it must be recounted from
> the code.** 244 reported three — credit, the grace timer, `close()` — and there
> are four: `_fcForget` wakes a parked sender when the call ends. That is the
> wake 206 added, 211 measured at 30 stranded senders against 0, and 210 ablated.
> A sweep that reports the previous sweep's number carries an undercount forward
> for as long as it is repeated.

## Round 434 — it is FIVE, and the code moved

```
             round 244   round 322   round 434
wake paths       3           4           5
```

Recounted from the code, as the paragraph above demands. Every `_wake` /
`wakeAll` call site in `flow_controller.dart`:

```
:291  the legacy grace timer expiring          counted since 244
:378  _onGrant           per-STREAM credit     counted since 244
:537  handleInbound      CONNECTION credit     NEVER COUNTED
:593  forget             the call ending       added by 322
:606  close                                    counted since 244
```

`:537` is not a second view of `:378`. Connection credit is shared and
per-stream credit is not; they arrive on different headers and neither implies
the other. It has existed since connection-level flow control did, and three
sweeps walked past it.

> **The warning above was right and still not sufficient: recounting catches an
> undercount only if the recount is EXHAUSTIVE.** 322 recounted and found the
> fourth by looking where the previous round had looked. The fifth needed
> enumerating every call site of the wake, mechanically, and asking what method
> each sits in — which is a grep, not a reading.

**And the mechanism MOVED.** A grep for this lens's own names — `_fcAwaitCredit`,
`_fcOnGrant`, `_fcForget` — now returns http2 only. Core's parking left
`channel_transport.dart` for a dedicated `RpcFlowController`
(`src/rpc/transports/flow_controller.dart`), where they are `awaitCredit`,
`_onGrant` and `forget`. A detector written against the old names reads as a
clean sweep of a file that no longer holds the mechanism.

All eight of P-10's cells reproduce, and its ablation still starves the sender —
which was not a given once a second wake path was known to exist. The sender
parks on per-stream credit, and connection credit alone does not admit a
message, so refusing `_onGrant` still hangs the draining call at 20 s.

`../rounds/434-the-fifth-wake-nobody-counted.md`.

## Round 717 — six wake paths, and the HTTP/1.1 upload

The sixth is `_noteMessagesLegacy` (`:694`), added with message credit in
round 709. It releases senders parked on seeded message credit when a peer
grants bytes without the messages header. Message credit is debited and
credited by the same predicate, `carriesMessage`. All four P-10 cells
reproduce.

The HTTP/1.1 half had never had a bench. `_fireRequest` writes the whole body
before it can see any response, which is this lens's shape exactly. It is
covered from above: the unary caller's deadline is on the response completer,
and its `finally` calls `releaseStreamId`, which aborts the request mid-pipe.
Measured by P-233: 2432 KiB and a closed socket, against 8192 KiB on an open
socket with the abort removed. rpc_dart's own server never stops reading. It
reads to the end past the size limit, so the shape needs a foreign server.
`../rounds/717-the-deadline-still-sits-above-the-write.md`.

## Round 743 — a shared close spreads a hang, so check its bound

Round 732 made concurrent endpoint `close()` calls share one future. A
second close can no longer escape a hung first one, so every unbounded await
under `_closeResources()` now traps both. The only await there that runs user
code is the call-scope disposer, bounded by `RpcCallScope.disposerTimeout`.
P-247: two closes over four stuck handlers return in 404 ms, and both hang
with the bound lifted. **When a fix makes callers share a future, look again
at the bounds beneath it.** `../rounds/743-a-shared-close-is-still-bounded.md`.

- **Round 758** — six wake paths by `find_callers`, the same six as 717; P-10
  unchanged, its `_onGrant` ablation still hangs the draining call at 20 s while
  the answered one returns in 0.4 s. `../rounds/758-the-wake-paths-recounted-again.md`.
