---
round: 843
verdict: CLEAN
packages: [rpc_dart_conformance]
lens: RPC-21
bench: none — the bench is `lifecycle_model_test.dart`, a test in the gate, run with its seed list and sequence length changed in place and restored
commit: yes
release: none
---

# Round 843 — the lifecycle model on fifty-four more seeds

## Target

Network-audit method §4, level 3: stateful sequences against a real server.
The conformance package's lifecycle model runs twelve fixed seeds of forty
operations on every member; a seed is the whole sequence, so the gate keeps
exercising the same twelve. RPC-21 (drive each lifecycle step out of order and
twice) is what the model generates. Before this, RPC-02's stale sweep was
weighed and not taken: `forTrailer(` has 22 call sites, as at round 818, and
no refusal path was added in `lib/` since its sweep commit.

## Hypothesis

A sequence the twelve seeds never produce breaks an invariant the model
checks after every step: a call ending twice or not at all within its trigger
plus 1 s (I-1), an error reaching the zone (I-4), a handler or timer or gauge
left behind (I-5), or a call ending other than its handler and deadline say.

## Before

```
run                                     cells   passed   failed   skipped
seeds 13-48, 40 ops                     216     184      0        38
seeds 13-30, 120 ops                    114     94       0        20
control: pinned cells, --run-skipped    6       4        1 (http2)  1 (wasm)
```

The skipped cells are the wasm member (outside the workspace, covered by
`test:wasm`) and the http2 pinned cell already marked KNOWN FAILING. The
control re-runs that cell: it fails with "[ending] expected the handler's
ABORTED, got status 9", so the model still sees a defect where one exists.

## Mechanism

None found.

## After

n/a — nothing to fix.

## Canary

n/a — no fix. The control row is the model's own: a known defect it reports.

## Gate

No library change; the seed list and length were restored (`git status`
clean before the record).

## Siblings

—

## Not fixed

Nothing found. wasm is outside this run, as in every gate run of the model.

## Links

Lens `../lenses/RPC-21-drive-the-lifecycle-twice.md`. Negative
`../checked/C-82-the-lifecycle-model-on-fifty-four-more-seeds.md`. Lead
`../backlog/B-283-a-request-sent-after-a-paused-http2-call-failed-loses-its-status.md`
(the control's cell).
