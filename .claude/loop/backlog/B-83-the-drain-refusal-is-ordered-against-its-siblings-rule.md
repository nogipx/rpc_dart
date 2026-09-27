---
status: decided by owner (round 445)
round: 444 — re-read against the tree, never measured
commit: 67303ea6
paths: [packages/core/rpc_dart/lib/src/endpoint/responder_pipeline.dart]
probe: —
reason: cost — split out of B-70 item 11; the consequence is a refusal on a stream that should have been answered, which needs a race to observe
---

# B-83 — the drain refusal is ordered one way, the ceiling refusal the other

Two refusals in `responder_pipeline.dart`, sitting either side of the same
closed-stream guard:

```
  ~613  drain refusal, UNAVAILABLE
        tests `_respIsDraining && _respStreams[id] == null`
        i.e. BEFORE the closed-stream guard at ~658
        no comment

  ~681  ceiling refusal, RESOURCE_EXHAUSTED
        sits AFTER the guard, and carries a comment explaining that it must
```

The sibling states the rule and the drain branch gets the opposite order with
nothing explaining why.

**What the order decides**: whether a frame arriving on a stream that is already
closed gets the drain refusal or the closed-stream handling. On the ceiling side
somebody worked out that the guard has to come first and wrote it down; on the
drain side nobody did, so this is either an undocumented specialisation or the
bug the other comment exists to prevent.

RPC-25's third detector step is the whole job here: ask of each copy what it
does that the other does not, and whether that is deliberate.

Bench: a call arriving on a closed stream id while the endpoint is draining,
against the same arrival while it is at the ceiling. The reading is the status
the caller gets and whether the stream state is resurrected — `_respStreams`
before and after.

Related and already closed: B-59 (a peer arriving while stopped) and round 414's
`markDraining` work. Read those before building anything.

## Owner decision

**Take it. Run the two-row bench, then align the drain refusal with the
sibling's documented order — unless the bench shows the specialisation is
deliberate.**

The bench is the deliverable either way: the status the caller gets on each of
the two arrivals, and whether `_respStreams` is resurrected. Read B-59 and round
414's `markDraining` work before building, as the lead says.

If the order turns out to be deliberate, the round's output is the missing
comment, not a code change — an undocumented specialisation that survives a
measurement should stop being undocumented.

Changing which status a caller sees on that race is a behaviour change, so it
gets a CHANGELOG line even though the blast radius is small.
