---
round: 321
verdict: FIXED
packages: [rpc_dart_http]
lens: RPC-15
bench: none
commit: yes
---

# Round 321 — a number that could not name its own cause

## Target

Not the queue. The owner pasted a CI failure mid-round:

```
[rpc_dart_http]: 00:17 +121 -1: aborted_body_frees_the_pipeline_stream_test.dart
  Expected: a value greater than <0>
    Actual: <0>
  the aborted requests must reach the transport at all
```

This is the loop's own test, and its second CI failure with the same `Actual:
<0>`. Round 314 already spent a round on the first one. A gate the loop wrote
that goes red on healthy code outranks RPC-09's re-sweep, which keeps.

## Hypothesis

Round 314 diagnosed the first flake as a window problem and left a second cause
in a comment: `_abortMidBody` destroys its socket at the flush, so a request is
answered by a read ERROR promptly rather than by `bodyReadTimeout` two seconds
later, and the rise is too brief to sample. If true, the residency is a few
milliseconds against a 5 ms poll and the guard is losing a race.

## Before

Probe: `packages/transport/rpc_dart_http/.dart_tool/probe/pending_residency.dart`
— four sockets promise a 100000-byte body and send five bytes, one arm
destroying the socket and one holding it, against a tight sampler that also
counts what a 5 ms sampler would have seen.

```
                        destroy      hold
peak pendingRequests    4 of 4       4 of 4
residency > 0           2009 ms      2006 ms
at the test's cadence   401 of 1191  401 of 1200
```

**The hypothesis is false, and so is the comment that stated it.** Both arms are
released by `bodyReadTimeout`, not by a read error — destroying the socket costs
the server exactly the same 2009 ms — and a 5 ms sampler hits 401 times. There
was never a race to lose. The full workspace `test:unit` was run loaded, twice,
and the test passed both times.

## Mechanism

The guard is level-triggered on a gauge that rises and falls, read by polling.
Whatever starves the sampler on a CI runner — the surviving candidate is isolate
starvation under `melos exec --concurrency 4` on a small runner, where a 5 ms
delay becomes a multi-second gap wide enough to straddle the whole 2 s event —
**`0` is what a poll reports both when nothing arrived and when it did not look.
The number cannot name its own cause, which is why one round of fixing it was
not enough to end it.**

Each of the three shapes this check has had asked the gauge a different
question — a simultaneous count, then a peak, then a peak over an earlier
window — and none of them changed that.

## After

The arrival check is read at the PEER and no longer sampled. The sockets stay
open, and each reports the first line the server answers:

```
                              answers               guard
healthy                       4x HTTP/1.1 408       passes
never reached the transport   4x closed             fails, and says so
mitigation removed            4x STILL DRAINING     fails, and says so
```

`408` is emitted at one place in this transport — the accepted path's catch, on
`TimeoutException` — and every pre-registration refusal answers its own code
through `_reject`. So a 408 per socket is strictly stronger than
`pendingRequests > 0`: it says the request reached the transport AND that
`bodyReadTimeout` is what released it, which the next expectation had assumed
and never checked.

## Canary

Four, run rather than argued. The first three switch off one thing each:

- content-type `text/plain`, so the requests are refused before registration:
  `Actual: ['closed', 'closed', 'closed', 'closed']`.
- `bodyReadTimeout: null`, the mitigation itself removed:
  `Actual: ['STILL DRAINING', 'STILL DRAINING', ...]`.
- `socket.destroy()` restored at the flush, so the hold is undone:
  `Actual: ['closed', 'closed', 'closed', 'closed']` — holding is load-bearing,
  not tidying.

**The fourth is the one that makes this a measurement rather than an argument.**
The OLD polled guard, put back and run against the first ablation — requests
that genuinely never reach registration — answers:

```
Expected: a value greater than <0>
  Actual: <0>
```

which is the owner's CI paste, character for character, on a scenario where the
new guard says `closed`. The old guard is not merely weaker; it is mute, and the
comparison is direct because both were run on the same ablation.

## Gate

`melos run analyze` clean over 21 packages plus `rpc_dart_wasm`;
`melos run format:check` clean; `melos run test:unit` 14 packages, 0 failures;
`rpc_dart_http` 123 tests green on its own and inside the loaded run.

## Not fixed

**The CI RUN was not reproduced here, and this round does not claim to have
identified what starves the sampler on that machine.** The starvation account
above is the surviving candidate, not a measurement. What was reproduced is the
MESSAGE: the fourth canary produces `Actual: <0>` from the old guard on demand,
which is the point — that string is reachable from more than one cause, and
that is the defect.

RPC-09's re-sweep, and RPC-14 and RPC-19 behind it, are where 319's queue was
left.

## Links

RPC-15 (`applied:` gains 321) — the lens is about the loop's own records, and
round 314's was wrong about its own diagnosis in exactly the way RPC-15's
closing note warns: suspect the observable before the code.

New lesson `L-11`. The probe is a probe, not a bench: it has two arms but no
control showing it can see a defect, so it gets no `P-N`.
