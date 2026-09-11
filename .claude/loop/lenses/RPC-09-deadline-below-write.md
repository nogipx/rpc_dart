---
refines: U-16
paths: [packages/core/rpc_dart/lib/**, packages/transport/rpc_dart_http/lib/**]
applies: the client writes the request and awaits the reply on one channel
breaks: a hang that never ends.
applied: [210, 221, 244, 322]
status: swept here (round 322, 9bb632e0)
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
