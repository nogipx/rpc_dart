---
round: 331
verdict: FIXED
packages: [rpc_dart]
lens: RPC-25
bench: none
commit: yes
---

# Round 331 — deduplication that extends coverage

## Target

Round 330 noticed in passing that `caller_pipeline.dart` holds three stream
bridges, two guarding their controller and one not, and filed it as "RPC-25's
drift shape — harmless here". It compared exactly one property of them. RPC-25's
bar is the drift, so the comparison was owed properly.

## Hypothesis

The two OUTER bridges — `serverStream`'s and `bidirectionalStream`'s — have
drifted somewhere round 330 did not look.

## Before

Wrong, and the way it is wrong is the round. Normalising the type parameter and
the cancel message and diffing the two blocks:

```
identical, modulo `TResponse` vs `R` and the reason string
37 non-comment lines, twice
```

No drift at all. By RPC-25's own bar — *the defect is not the duplication, it is
the divergence* — that is a decline, and three of the last four RPC-25 rounds
(316, 317, 318) declined on exactly that reasoning.

**The reason not to decline is coverage, and it is measurable.** The one test
that pins this code —
`test/audit/audit_server_stream_context_not_poisoned_test.dart` — has no bidi
arm. So on the pre-extraction tree:

```
ablate the guard in                       suite result
  serverStream's copy                     +1434 ~1 -1   caught
  bidirectionalStream's copy              +1435 ~1      NOTHING CAUGHT IT
```

Two identical guards, one covered and one not, and nothing in the file says
which is which.

## Mechanism

The `if (!finished)` check is the rule that stops a normal completion poisoning
a REUSED `RpcContext`'s cancellation token — round 235's finding, and the reason
the next call on that context would otherwise throw `RpcCancelledException`. It
was written twice and tested once.

Extracting both into `_bridgeCallerResponses<T>` makes the existing test cover
both shapes, because there is now one implementation to cover.

## After

```
caller_pipeline.dart      856 -> 838 lines   (-53 code, +35 doc)
rpc_dart suite            +1435 ~1, unchanged
ablate the extracted guard                   +1434 ~1 -1   caught
```

The helper carries the three jobs and the two rules once, where they were
duplicated or — for the bidi copy's `onPause`/`onResume` — reduced to "same
demand hand-off as the server-stream controller above", a comment that points at
code a hundred lines away and goes stale silently.

## Canary

Two, and the second is the one that justifies the round.

1. **The extracted guard.** `if (!finished)` removed from
   `_bridgeCallerResponses`: `+1434 ~1 -1`, and the single red is
   `audit_server_stream_context_not_poisoned_test.dart` — the test for exactly
   that rule. The extraction is covered, not merely compiled.
2. **The same guard, on the pre-extraction tree, in the BIDI copy**, restored
   from `HEAD`: `+1435 ~1`, zero red. That is the measurement: identical code,
   one copy watched and one not.

## Gate

`melos run analyze` clean over 21 packages plus `rpc_dart_wasm`;
`format:check` clean; `test:unit` 14 packages, 0 failures — `rpc_dart`
`+1435 ~1`, `rpc_dart_http2` `+204`, `rpc_dart_websocket` `+137`, unchanged.

## Not fixed

The THIRD bridge, `_buildBidirectionalStream`'s request-pump controller, is left
alone. It is a different job — it pumps requests outward and owns `cleanup()` —
and RPC-25's own rule is that same-shaped code with a different LIFETIME must
not be merged. C-35 already records why its missing `isClosed` guard is
unreachable.

I edited this file with a `sed` splice first, mangled the class structure, and
restored from git. There is a standing note not to do that; it cost one restore
and proved its own point.

## Links

RPC-25 (`applied:` gains 331). What this adds, and it is a genuine extension of
the lens: **duplication with NO divergence can still be worth removing, when the
copies are unequally covered.** The lens's bar has been "the finding is the
drift" since round 308, which is why 316-318 declined; this is the first case
where the copies were identical and removing them still bought something
measurable — one test now guards two call shapes instead of one.

> **Ask which copy the tests reach, not only whether the copies agree.** Two
> identical blocks are not equally safe if only one is watched, and nothing in
> either file records that.
