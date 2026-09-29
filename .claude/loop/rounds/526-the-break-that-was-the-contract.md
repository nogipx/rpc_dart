---
round: 526
verdict: CLEAN
packages: [rpc_dart]
lens: RPC-23
bench: none — decided by reading, and filed as a severity negative
commit: yes
---

# Round 526 — the break that was the contract

## Target

B-129's item 16, the third and last of that lead's items this run has examined.

Lens RPC-23, still pointed at the lead rather than the code: round 521 argued B-129
mis-states severity in both directions, and the previous two splits went one way. This
one goes the other.

## Hypothesis

`break` after the first decoded unary response silently drops further messages, and the
"extra response" warning below it is unreachable.

## Before

No measurement — this is a reading, and it is recorded as one.

**The drop is the gRPC contract.** A unary response is exactly one message; a server
sending two is misbehaving, and taking the first is what a gRPC client does. The
comment on the line says so.

**The warning is reachable**, by the ordering the lead did not consider: a DATA frame
arriving AFTER the status trailer has completed the call. Then `completer.isCompleted`
is true on the first message of that chunk, the `else` branch runs, and the warning is
logged.

What cannot happen is the warning firing for a second message inside a chunk whose
first completed nothing — `break` leaves the loop first. So the real gap is narrower
than filed: **a second response inside ONE chunk, before the status, is dropped without
a word**, while two split across chunks with a status between them IS reported.

## Mechanism

None — there is no defect. The `break` implements the contract; the silence in one
ordering is the only arguable part.

## After

n/a — nothing changed.

## Canary

n/a. **What stands in for it is reading BOTH orderings**, which is what the lead did
not do: data-then-status takes the `break`, status-then-data takes the `else`. The
"unreachable" claim comes from following one path and concluding about the branch.

## Gate

Not run: nothing in `lib/` or `test/` changed.

## Not fixed

**Nothing to fix.** The negative is `checked/C-60`.

**The remaining gap is one line and has no defect behind it**: making the in-chunk drop
observable — a counter, or a once-only log — would close it. Dropping is correct; only
the silence is arguable, and arguing it is a preference.

**Nothing was RUN**, and the record says so. No probe drove a server sending two
responses in one chunk. A round that wanted evidence rather than a reading would build
that, and it would be measuring how a misbehaving peer is reported rather than a fault
of this library's.

## What this run established about B-129 as a whole

Three of its eighteen items were examined, and the lead's severity was wrong in **both**
directions:

- **item 14** was filed as hygiene and is a DoS surface — the effective metadata
  ceiling was 16x the configured one (B-197, fixed in round 524).
- **item 15** was filed as hygiene and is a reachable interop failure — a 129-to-1018
  character band of service names is routable and uncallable (B-198, measured in round
  525, not yet fixed).
- **item 16** was filed as a defect with an "unreachable" warning and is neither.

**A grab-bag lead does not merely under-state severity; it randomises it.** That is the
argument for splitting the remaining fifteen before anyone works them, and it is
stronger now than when round 521 made it.

## Links

Lens RPC-23. Negative `checked/C-60`. Lead B-129 (item 16 closed; fifteen items
unexamined). Rounds 521, 523, 524, 525 are the rest of this sequence.
