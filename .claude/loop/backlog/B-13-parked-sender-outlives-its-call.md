---
status: open
round: 210
commit: beed83e5
paths: [packages/core/rpc_dart/lib/src/rpc/transports/**]
probe: packages/core/rpc_dart/.dart_tool/probe/parked_sender_learns.dart
reason: bench — the call completes either way, so nothing at the call level can show a parked sender that never unwinds; a different observable is needed
---

# B-13 — does an abandoned upload leave a sender parked forever?

Round 210 set out to check RPC-09 (a send parked in the flow-control window
outliving the answer) and found the shape cannot arise: the caller's call future
resolves on the RESPONSE path, independently of the request pump. An ablation
removing `_fcWake` from `_fcForget` did not move either number — the case still
completed in 0.4 s.

That is a clean result for the hang. It also means the ablation proved something
uncomfortable: **`_fcWake` in `_fcForget` is not load-bearing for anything this
probe can see.** Round 206 added it so "a torn-down call can never leave a
sender waiting forever", and that claim is now untested by any measurement in
the journal.

## What to measure

Not the call. A `sendMessage` future parked in `_fcAwaitCredit` when the stream
is torn down: does it ever complete? Observables that would show it:

- the request generator: if the pump is stuck the generator is neither drained
  nor cancelled, so its `finally` never runs. Count that directly.
- `flowControlStateSizes['waiters']` after N abandoned uploads — it is already
  exposed, and it is the counter the wake exists to drain.

The second is the cheap one and needs no new plumbing: park a sender, tear the
call down, and read `waiters`. With the wake it should return to 0; ablate the
wake and it should stay at N. That ablation IS the control, so the bench is
valid the moment the two differ.

## Why it matters

One leaked completer per abandoned upload, on a long-lived connection, with a
peer that chooses when to abandon. Bounded per call but unbounded in aggregate,
and invisible: every call reports success.

## Owner decision

—
