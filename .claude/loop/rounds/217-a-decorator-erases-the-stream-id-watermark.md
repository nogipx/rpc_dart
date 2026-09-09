---
round: 217
verdict: DEFERRED
packages: [rpc_dart]
lens: RPC-03
bench: P-09 — new
budget: probes 0/3, canaries 0/3
review: self — the session forbids the Agent tool unless the user asks, so the `loop.py review` prompt was answered in full against the record and the bench; approved 9 of 10, Q6 n/a (no fix, so no canary)
commit: no
---

# Round 217 — a decorator erases the stream-id watermark

## Target

RPC-03, never applied. Its damage is the worst class in the set: a dead call's
teardown acting on a LIVE one, silently. The detector is every place a transport
is replaced under a living endpoint — and `RpcClientConnection` is the one that
replaces it wholesale rather than reconnecting in place.

## Hypothesis

Both hops of the watermark guard on the capability and return silently without
it:

    _noteIdWatermark : if (inner is! IRpcStreamIdSequence) return;
    attach           : if (inner is IRpcStreamIdSequence && ...) resume...

The existing test's header names that requirement — "the wrapper must FORWARD
the capability, or the `is` check finds only IRpcTransport and the watermark is
silently never carried" — and no test drives it. Round 209 showed that an
application decorator dropping a capability is a real thing people write.

## Before

```
  factory returns          id before   id after   handlers ended
  the transport itself         1           3          0 -> 0     <- control
  a plain decorator            1           1          0 -> 1
```

Probe:
`packages/core/rpc_dart/.dart_tool/probe/watermark_survives_a_decorator.dart`
(P-09).

`0 -> 1` is a live bidirectional call whose request stream was half-closed by an
unrelated dead call's teardown, so the server finished serving it. The id
column alone would be a curiosity; this column is the defect.

## Mechanism

The decorator forwards every `IRpcTransport` member and declares nothing else.
`RpcClientConnection` therefore cannot read the outgoing transport's cursor and
cannot seed the incoming one, so the replacement starts its ids at 1 while the
first call still holds 1. A stale `finishSending` then lands on the live call.

Unlike http2's `_preserveCapabilities` (round 209), restoring it is not
available here: that class wraps a decorator it built around a transport IT
still holds, whereas this factory returns the decorator and keeps the real
transport inside it. There is nothing to fall back to.

## After

n/a — not fixed.

## Canary

n/a — no fix. The control is the same rig with the decorator removed: same
swap, same stale teardown, id 3 instead of 1 and no handler ended.

## Gate

No code changed. `git diff` is empty; the gate is the one HEAD passed at 212.

## Not fixed

Because the fix carries a design choice that is the owner's, and because both
candidates change behaviour in a resilience class applications are pointed at
for auto-reconnect:

1. **Track the generation of every id the proxy issues, and drop stream-scoped
   operations for ids from a retired transport.** Capability-independent, so it
   also covers a stale id used when the watermark WAS carried. Cost: a stale
   `finishSending` becomes a silent no-op instead of an error, and it adds a
   per-id map on the hot path, bounded by our own traffic and pruned on release.
2. **Refuse a factory transport that does not implement `IRpcStreamIdSequence`,
   loudly, at attach time.** Smallest and safest to reason about; cost is that
   an application with a working decorator starts failing to connect at all,
   which is a breaking change for anyone doing this today.

A third option, warning and carrying on, is not one: the config's bar rules out
sharper diagnostics as a round's product, and a warning leaves the data loss in
place.

Filed as B-17. This is worth putting in front of the owner rather than choosing
for them: option 1 changes what a stale call does, option 2 changes who can
connect.

## Links

Lead `../backlog/B-17-watermark-lost-through-a-decorator.md` — new, awaiting owner.
Bench `../probes/P-09-watermark-survives-a-decorator.md` — new, validated by its control.
Lens `../lenses/RPC-03-stream-ids-restart-on-reconnect.md` — `applied: [217]`,
with the decorator door recorded.
Round `209-a-decorator-can-switch-the-bound-off.md` — the same class, other capability.
