---
round: 248
verdict: DEFERRED
packages: [rpc_dart]
lens: RPC-15
bench: none
commit: no
---

# Round 248 — the obvious fix for B-22 is wrong

## Target

B-22, `decided by owner (round 247)`. An owner decision outranks anything the
round would pick for itself.

## Hypothesis

The wedge has a mechanism narrow enough to name in code, rather than being a
property of flow control in general.

## Before

Two paths repay the connection pool, and a paused consumer reaches neither:

```
onCancel of the stream controller   :447-453   runs on explicit cancel, and
                                               "again when a closed controller
                                               reaches done"
_fcForget                           :1181-1188 repays ONLY if the consumer is
                                               absent or has no listener
```

A paused subscription never receives `done`. So `onCancel` cannot fire, and
`_fcForget` skipped the repay precisely BECAUSE a listener existed. No bench: the
detector is two call sites and the question is answered by reading them.

## Mechanism

That condition is B-22's title restated in code.

## After

n/a — nothing shipped. **The fix that suggests itself is wrong**, which is what
this round bought. Dropping the `hasListener` guard so `_fcForget` always repays
reads correctly until the consumer drains afterwards:

    _fcCredit(streamId, bytes) -> _fcCreditConnection(bytes)   (:1046, uncond.)

The bytes were already returned and `_fcSettleOwed` finds no entry to clear, so
the connection is credited twice and its window inflates past the configured
size. Round 231 hit the same wall from the other side.

## Canary

n/a

## Gate

Nothing shipped.

## Not fixed

All of it. The round also disproved its own earlier guess — a tracking-cap
overflow — one grep later: `_fcTrackCap` IS `maxActiveStreams`, so the ledger
normally holds every live stream. Both the guess and its refutation stay in the
lead so nobody re-derives either.

## Links

Lens RPC-15 · lead B-22 · the shared commit with round 249 is
`77ee136a`, which the one-commit-per-round rule would now split.
