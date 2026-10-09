---
round: 215
verdict: CLEAN
packages: [rpc_dart]
lens: RPC-05
bench: P-07 — new
budget: probes 0/3, canaries 0/3
review: self — the session forbids the Agent tool unless the user asks, so the `loop.py review` prompt was answered in full against the record, the bench and both controls; approved 10 of 10
commit: no
---

# Round 215 — the pre-method budget comes back

## Target

B-16, the gap round 214 left in RPC-05's detector and the highest-severity
charge/release pair remaining. Its own comment records what it exists to stop:
250.7 MiB pushed at a stream id never opened with metadata cost a server
495.2 MiB of RSS, unauthenticated, with three hand-built frames on a plain
WebSocket.

## Hypothesis

`_respPreMethodBytes` is charged when a payload arrives for a stream with no
method, and released either when metadata replays the buffer or by
`_cleanupStream`. Some teardown path reaches neither, and the budget fills with
bytes from streams that are long gone.

## Before

```
ceiling 256 KiB (maxMessageLengthBytes), 64 KiB parked per round, six rounds.
KiB held after each, read from preMethodBufferedBytes:

                     released                  ablated
  metadata      [0, 0, 0, 0, 0, 0]     [64,128,192,256,256,256]
  endStream     [64,128,192,256,256,256]   [64,128,192,256,256,256]
  endStreamShort[0, 0, 0, 0, 0, 0]     [64,128,192,256,256,256]
  reclaim       [0, 0, 0, 0, 0, 0]     [64,128,192,256,256,256]
```

Probe: `packages/core/rpc_dart/.dart_tool/probe/pre_method_budget_returns.dart`
(P-07).

## Mechanism

The hypothesis does not hold, and the `endStream` row is why it looked as though
it did. A peer that half-closes without ever naming a method hits
`_handleEndOfStream`'s `methodKey == null` branch, which sets
`endOfStreamPending` and returns rather than cleaning up — deliberately, because
on a reordering transport the metadata may still be in flight behind the EOS,
and that reorder window is the entire reason the buffer exists.

So the bytes are held, and the bound is TIME: `endStreamShort` is the identical
run with `halfOpenStreamTimeout` at 300 ms instead of 60 s, and it reads zero
throughout. Both bounds work — volume caps at the ceiling and refuses beyond it,
time caps at the half-open reclaim.

The ablation is what separates "held by the timeout" from "never released":
with `_releasePreMethodBytes` made a no-op, all four modes climb and stick,
including the two that are clean in the real code.

## After

n/a — nothing changed. `git diff` is empty; the ablation was reverted in place.

## Canary

n/a — no fix. The `metadata` mode and the ablation are the two controls, and
they answer different questions: the first that the bench is not merely watching
bytes get parked, the second that it can see a release that never happens.

## Gate

No code changed, so the gate is the one HEAD passed at round 212.

## Not fixed

**A correction to round 214's own record, per rule one.** That round listed
"`maxBufferedBytes` / the pre-method byte budget" as one un-swept item. They are
two different things and only one of them is a charge/release pair.
`maxBufferedBytes` is the gRPC parser's reassembly ceiling in `parser.dart` —
`if (_state.available > _maxBufferedBytes) throw` — a threshold read off the
buffer's current occupancy, with no counter that can desync from it, so it
belongs with the pure predicates and cannot suffer this shape. The pre-method
budget's ceiling is `maxMessageLengthBytes`, not `maxBufferedBytes`. Corrected in
the lens and noted in round 214.

What is measured but NOT a defect, and is now a negative so it is not re-hunted:
a peer can occupy its connection's whole pre-method budget for
`halfOpenStreamTimeout` — 60 s by default — with two tiny frames per stream, and
while it is full, a legitimately reordered frame on that connection is refused.
The refusal fails only the offending stream, and a connection is per client, so
this is self-harm rather than a way to hurt anyone else. Filed as C-20.

With this, every `RpcSecurityPolicy` field that holds state has been swept, so
RPC-05 becomes `swept here`.

## Links

Lead `../backlog/B-16-pre-method-byte-budget-release.md` — closed by this round.
Bench `../probes/P-07-pre-method-budget-returns.md` — new, two controls.
Negative `../checked/C-20-pre-method-budget-held-for-the-reclaim.md` — new.
Lens `../lenses/RPC-05-concurrency-limit-charge-point.md` — `swept here (round 215, d0612f96)`,
with the `maxBufferedBytes` confusion corrected.
Round `214-handler-slots-come-back.md` — the other half of the same detector.
