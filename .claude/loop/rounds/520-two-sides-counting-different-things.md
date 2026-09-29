---
round: 520
verdict: DEFERRED
packages: [rpc_dart]
lens: RPC-05
bench: P-157 — new
commit: yes
---

# Round 520 — two sides counting different things

## Target

The client releasing a stream slot at half-close — thirty-fifth in the audit's rank.

Lens RPC-05, the charge/release lens, at its most literal: the charge is correct and
the RELEASE point is too early, so the limit bounds a shorter interval than its name
claims.

## Hypothesis

`finishSending` and `_markFinished` release the slot, so a client's
`maxActiveStreams` counts only calls that have not half-closed — and a unary call
awaiting its response is not counted.

## Before

```
ceiling on BOTH sides       4 refused with RESOURCE_EXHAUSTED
ceiling on the CLIENT only  0 refused — all eight calls completed
```

Bench:
`packages/core/rpc_dart/.dart_tool/probe/b128_client_ceiling_after_half_close.dart`

**CONFIRMED.** Four calls parked awaiting responses leave four slots free, and a
second batch of four is admitted in full against a ceiling of four.

**The two runs are the finding, not just the second one.** With one policy on both
sides the refusals appeared and the lead looked refuted — but those came from the
SERVER, whose ceiling counts the interval the name implies. Separating the policies
shows the two sides counting different things under one field.

`RpcChannelTransport.pair(policy:)` applies one policy to both, so the first run was
ambiguous by construction: a server refusing at its own ceiling is indistinguishable
from a client doing so, seen from the caller. The rig now builds each side over a
hand-made byte pipe with its own policy.

## Mechanism

A unary call's request is complete the moment it is sent, so `finishSending` runs
immediately and releases the slot. The call is then outstanding — a stream id is
held, a response is awaited, memory is retained — and uncounted.

## After

Nothing. `lib/` is unchanged.

## Canary

n/a — nothing was fixed. The both-sides run stands in for it: it proves the ceiling
mechanism works and the rig can provoke a refusal, so the zero in the client-only run
is the client declining to count rather than the probe failing to fill anything.

## Gate

Not run: nothing in `lib/` or `test/` changed.

## Not fixed

**Releasing later is a change to stream accounting on the client's hot path, and the
failure mode of getting it wrong is the bad direction.** A slot released too early
admits too much; a slot never released refuses every subsequent call for the life of
the connection. Rounds 518 and 519 both declined hot-path changes on partial
information, and this one has a worse blast radius than either.

What a fix needs, and what this round did not establish: which event is the right
release point for each of the four call shapes. `releaseStreamId` and the terminal
inbound frame are the sketch's candidates, and they are not obviously the same event
— a call cancelled locally never receives a terminal frame.

**The streaming shapes are unmeasured.** A client-stream call holds its request
stream open, so it may already be counted for its whole life, which would mean the
field's meaning varies by shape as well as by side. That is worth knowing before
choosing a release point.

**The cheaper half of the sketch is available and unclaimed: "document which count is
meant".** The two sides demonstrably count different intervals under one name, and
saying so costs nothing. Round 518 left the same choice open for a transport
invariant, and round 507's `IRpcChannel.incoming` is the precedent for taking it.

## Links

Lens RPC-05. Bench P-157 (new). Lead B-128 (awaiting owner). B-75 measured this
ceiling for synchronously started calls, which is the case this one does not cover.
