---
round: 868
verdict: INCONCLUSIVE
packages: [rpc_dart_http2]
lens: RPC-14
bench: P-334 — new
commit: yes
release: none
---

# Round 868 — the tiny-messages timeout, not reproduced under load

## Target

B-297: round 863's first full gate failed `tiny_messages_are_weighed_test`
at its post-release wait (`Future.wait(calls).timeout(20 s)`, line 113).
Round 860 found the isolate witness's flake to be load stretching a
deadline; the same shape was the first hypothesis here.

## Hypothesis

Under load the wait after the handlers are released grows past 20 s.
Fails if it stays far below 20 s under load.

## Before

```
P-334, copies at once:
n   queueing          post-release wait   outcomes
1   6.2 s             103 ms              status 8, status 8
4   8.5-9.1 s         100-222 ms          the same on all four
8   11.5-14.3 s       91-192 ms           the same on all eight
```

## Mechanism

Not established. The post-release wait does not grow with load. What does
is the queueing phase, which the test bounds with a 20 s deadline of its
own (lines 106-110) before it releases the handlers anyway: past that
deadline the uploads would still be running when the 20 s wait starts.
At 8x the queueing reached 14.3 s; the gate's load was not reproduced.

## After

n/a.

## Canary

n/a.

## Gate

No change.

## Siblings

—

## Not fixed

B-297 stays open with this data: 13 load runs, no timeout; the queueing
deadline is the candidate.

## Links

Lens `../lenses/RPC-14-timeout-abandons-work.md`. Bench
`../probes/P-334-the-phases-of-the-tiny-messages-witness.md`. Lead
`../backlog/B-297-the-tiny-messages-witness-times-out-under-the-gate.md`.
Round `860-a-failed-isolate-startup-exits-under-load.md`.
