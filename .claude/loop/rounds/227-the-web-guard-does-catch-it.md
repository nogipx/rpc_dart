---
round: 227
verdict: CLEAN
packages: [rpc_dart, rpc_blob]
lens: RPC-07
bench: none — the instrument is a planted hang and the smoke test's own exit code; three plant sites, the third reached the path
budget: probes 3/3, canaries 0/3
review: self — the session forbids the Agent tool unless the user asks; the `loop.py review` prompt was answered against the record. Approved 10 of 10
commit: yes
---

# Round 227 — the web guard does catch it

## Target

B-18, the owner decision: plant `async*` cancellation, "the one class with a
confirmed history on this project", and find out whether `test:web` notices.

## Hypothesis

The web guard is a census. It catches "this package no longer builds for JS" and
was never shown to catch a real dart2js bug class, so a planted one survives.

## Before

Two corrections came first, and both changed the round.

**The premise was wrong, and so was my own first measurement.** Grepping the ten
smoke-only files for `serverStream|clientStream|bidirectional` returned nothing,
and that was reported as "0 of 10 exercise streaming". False: they reach
streaming through higher-level APIs, and several are aimed squarely at this
class.

```
  rpc_blob       RPC get-stream cancel mid-download does not deadlock (web)
  rpc_data       direct-repo watchChanges + cancel (web)
                 direct-repo exportDatabase + cancel (web)
  rpc_websocket  caller close cancels subscription without deadlock
                 channel frame round-trips with 32-bit header (JS-safe)
```

"does not deadlock", "without deadlock", "JS-safe" — these were written AT the
classes B-18 says were never covered.

**The class itself no longer exists here.** Reverting the documented mitigation
at `responder_pipeline.dart:1604` — `unawaited(handlerSub.cancel())` to
`await handlerSub.cancel()`, the historical deadlock's exact shape — and running
core's cancellation tests:

```
  planted, VM      All tests passed
  planted, node    All tests passed
```

Green on both. The dart2js `async*` cancel-deadlock does not reproduce on Dart
3.10.1, so it cannot be used to test anything. The memory note calling it a
confirmed history is history.

## Mechanism

With the SDK bug gone, the answerable question is the one those test names
raise: **would the detector fire if a deadlock returned?** That is an ablation —
break what the test claims to protect, and see it go red.

Three plant sites, because the first two were reasoned rather than measured:

```
  responder_pipeline.dart:1604  await instead of unawaited   green — no bug here
  base_processor.dart:104       hang in the cancel notice    green — not awaited
  caller_pipeline.dart:480      hang in the stream's
                                controller onCancel          RED
```

The third is the hop `sub.cancel()` actually awaits, and its own comment says so
("StreamController with onCancel makes cancellation deterministic").

## After

```
RPC get-stream cancel mid-download does not deadlock (web)
  TimeoutException after 0:00:03.000000: Future not completed
  test/web_smoke_test.dart 63:5

RPC put/get/list round-trip (web)
  TimeoutException after 0:00:30.000000: Test timed out
```

The detector fired at exactly its own 3-second budget, on the line that sets it:
`await sub.cancel().timeout(const Duration(seconds: 3))`. The round-trip test
went red too, because `await for` teardown runs the same `onCancel` — so the
plant is squarely on the path both use.

The test is not decorative either: lines 60-61 assert `received > 0` and
`received < data.length ~/ 4096`, so the cancel provably lands mid-stream rather
than after the download finished.

Plant reverted; `git diff` empty and the file green again (`+2 All tests
passed`).

## Canary

The ablation IS the canary, and it has both directions: red with the hang in,
green with it out. The control for "the harness can pass at all" is the same
file's pre-plant run.

## Gate

No code changed — three plants, all reverted in place, `git diff` empty. The
gate proper is the one HEAD passed at round 226.

`melos run test:web` itself was run once as a baseline and FAILED, on
`Timed out waiting for Chrome to connect` in the `rpc_dart_isolate` Chrome step.
Rerunning that step alone exited 0, so it is the cold-start flake its own comment
in `pubspec.yaml` predicts, not a regression. The 11 node runs before it were
green.

## Not fixed

**B-18's premise does not survive, so it closes without the fix it asked for.**
The guard was called a census; for the cancel class it is a working detector with
a real assertion and a real budget, demonstrated by ablation. What is true is the
narrower thing round 219 measured: nine packages contribute a handful of
hand-written tests rather than a suite, so coverage is whatever those files
happen to exercise — but on this class they were written deliberately and they
work.

**Two failed plants are worth more than the successful one.** Both were placed by
reading the code and reasoning about which hop `cancel()` awaits, and both were
wrong; the third was found by grepping for `onCancel`. That is this repository's
oldest lesson ("measure every hop, don't reason about which one is wrong")
re-learned at a cost of two rounds' probe budget.

**Not attempted: the int-above-2^53 class.** The budget is spent. Note that
`rpc_dart_websocket`'s smoke test already carries a "32-bit header (JS-safe)"
case, so that class has a detector too; whether IT fires is unmeasured.

## Links

Lead `../backlog/B-18-web-guard-is-a-census-not-a-sweep.md` — closed by this
round, premise corrected.
Negative `../checked/C-25-web-smoke-catches-a-cancel-deadlock.md` — new.
Lens `../lenses/RPC-07-web-as-separate-runtime.md` — `applied: [227]`.
Round `219-what-the-web-gate-actually-covers.md` — the census this refines.
