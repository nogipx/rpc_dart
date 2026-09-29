---
status: closed (round 540)
round: 522
commit: 7cdaabf6
paths: [packages/transport/rpc_dart_websocket/lib/src/websocket_caller_transport.dart]
probe: none — no witness is possible while id resume masks it
reason: "structure confirmed by reading (the field is re-read after the await) but UNWITNESSABLE: id resume makes the stale release name an id that was never minted, so there is nothing to observe. The one-line fix has nothing to canary; whether to remove the coupling anyway is the owner's"
---

# B-130 — websocket heartbeat releases its id on whatever `_inner` is current by then

**Filed from the external audit of 2026-09-28** (core + transports, read in full,
transport findings re-checked against the code). Confidence from reading:
**medium**. Nothing here was measured; the witness below is the first
thing a round owes this lead, and it may refute it.

The probe creates the id on `_inner` and releases it in `finally { _inner.releaseStreamId(streamId); }`, which after a reconnect is the NEW connection — the stale-teardown hazard the class documents, harmless only because id resume keeps the ranges apart.

## The shape

`packages/transport/rpc_dart_websocket/lib/src/websocket_caller_transport.dart:165-192`.

## Why it matters

Relies on a second mechanism to be safe; any change to id resume makes the
heartbeat release a live call's id.

## Witness a round would build

Reconnect during a probe; assert which transport receives the release.

## Fix sketch

Capture `final inner = _inner;` for the probe.

## Round 522 — structure confirmed, no witness possible as it stands

The shape is exactly as filed, in four lines: `_inner.createStream()` at `:172`,
`await ... execute(...)`, then `_inner.releaseStreamId(streamId)` at `:188`. `_inner`
is re-read after the suspension.

**But it cannot be witnessed, for the reason this lead already gives:** *"harmless
only because id resume keeps the ranges apart."* The new transport resumes numbering
past the old one's last issued id, so the stale release names an id it has never
minted — a no-op. There is nothing to observe.

A witness would have to disable id resume first, and would then be demonstrating a
defect in a configuration the library does not ship. That is a legitimate ablation but
a different claim: *"safe only because of X"* rather than *"broken"*.

**So the one-line fix was NOT applied.** `final inner = _inner;` is obviously correct
and has nothing to canary, and a change with no evidence behind it is the one thing
the loop does not do.

## DECIDED in the round-540 review: CLOSED, no change

Nothing to observe, so nothing to canary — and a fix with no canary on a correct path is the
shape this journal refuses. The structure is real and read correctly: the field IS re-read
after the await. What makes it unwitnessable is another mechanism doing its job — id resume
means the stale release names an id that was never minted.

**What would reopen it**: any change to id resume, which is exactly the coupling this lead
names. Whoever touches `resumeStreamIdsAfter` should read this record first — that is what it
is for now.

## Owner decision

The fix buys **independence, not a repair**: the heartbeat would stop relying on id
resume for its safety. That is this lead's own argument — *"any change to id resume
makes the heartbeat release a live call's id"* — and it is an argument for changing
code whose behaviour is correct today.

Two ways:

1. **Apply the one-line capture** on the coupling argument alone. Cheap, safe, and
   removes a dependency between two unrelated mechanisms.
2. **Ask for the ablation round first** — disable id resume, show the release landing
   on a live id, and fix on evidence. More expensive, and it measures the coupling
   rather than a defect.
