---
round: 522
verdict: INCONCLUSIVE
packages: [rpc_dart_websocket]
lens: RPC-16
bench: none — no witness can exist while id resume masks it
commit: yes
---

# Round 522 — a defect masked by a second mechanism

## Target

The websocket heartbeat releasing its stream id on whatever `_inner` is current —
thirty-seventh in the audit's rank.

Lens RPC-16, *check before await*, in the form rounds 505 and 510 both found: a field
read before a suspension and read AGAIN after it, as though it were the same object.

## Hypothesis

The probe creates its id on `_inner` and releases it in `finally { _inner
.releaseStreamId(streamId); }`, so a reconnect during the probe sends the release to
the NEW connection.

## Before

**No measurement.** The structure is confirmed by reading, in four lines:

```dart
final streamId = _inner.createStream();          // :172
try {
  await RpcEndpointPingExchange(transport: _inner, ...).execute(...);
} finally {
  _inner.releaseStreamId(streamId);              // :188
}
```

`_inner` is re-read after the await. If it was swapped by a reconnect in between, the
id minted on the old transport is released on the new one.

## Mechanism

Exactly as filed. What this round adds is why it cannot be witnessed as it stands.

## After

Nothing. `lib/` is unchanged.

## Canary

n/a — nothing was fixed, and **that is the round's finding rather than a shortfall.**

## Why no witness was built

**The lead says so itself: *"harmless only because id resume keeps the ranges
apart."*** After a reconnect the new transport resumes numbering past the old one's
last issued id, so the stale release names an id the new transport has never minted
and it is a no-op.

So there is nothing to observe. A witness would have to disable id resume first — and
then it would be demonstrating a defect in a configuration the library does not ship.
That is a legitimate ablation, but it is a different claim: *"this is safe only
because of X"*, not *"this is broken"*.

**Applying the sketch's fix — `final inner = _inner;` — would be a change with no
evidence behind it and nothing to canary**, which is the one thing the loop does not
do. It is one line, it is obviously correct, and that is not the bar.

## Gate

Not run: nothing in `lib/` or `test/` changed.

## Not fixed

The one-line capture. What it buys is not a repair but **independence**: the
heartbeat would stop relying on id resume for its safety, so a future change to id
numbering could not turn this into a live-call id being released.

That is a real argument and it is the lead's own — *"any change to id resume makes the
heartbeat release a live call's id"*. It is also an argument for a change with no
observable behaviour today, which makes it the owner's call rather than a round's.

**What would change that:** a round willing to ablate id resume and show the release
landing on a live id. That measures the coupling rather than the defect, and it would
justify the fix on evidence instead of on reading.

## Links

Lens RPC-16, whose other two instances this run — rounds 505 and 510 — were both
witnessable and both fixed. This one is the same shape with a second mechanism in
front of it. Lead B-130 (open).
