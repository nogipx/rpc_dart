---
round: 702
verdict: CLEAN
packages: [rpc_dart_isolate]
lens: RPC-26
bench: none — repeated runs of the two Chrome files and of `test:web`, counted
commit: yes
release: none
---

# Round 702 — the Chrome flake is the shared invocation

## Target

B-215 and B-196: `rpc_dart_isolate`'s two Chrome suites failing at the load
stage, differently each run. B-215's witness: on a quiet machine (load under
3 at the start), N runs of each shape -- each file alone, both in one
invocation -- counting failures; if the split round 543 made shows no
difference, revert it.

## Hypothesis

Round 543's reading: `-j 1` serialises tests, not browsers, so one `dart test`
over both files starts the second Chrome while the first is closing, and the
second suite times out loading.

## Before

Started at load 2.34 (after a reboot; it rose to about 6 under the runs
themselves):

```
worker_startup_failure alone      5/5 pass
echo_worker alone                 5/5 pass
both in one invocation            2/5 pass   the failures: "loading <second file> [E]" (twice at 01:33), once the first
test:web as committed (split)     3/3 pass   0 [E] lines
```

## Mechanism

As round 543 read it: the failures come only when both files share one
invocation, and the failing suite is the one loading second. The split is
load-bearing and stays.

B-196 is the same failure from before the split (rounds 507 and 508,
`worker_startup_failure_test.dart` at the load stage).

## Fix

None. Round 543's split already is the fix.

## After

As Before.

## Canary

The shared-invocation shape is the canary: 3 of 5 red, against 10 of 10 alone
and 3 of 3 for the gate.

## The verdict questions

1. Yes: the shared shape is the canary, the separate runs the control.
2. Yes: the shapes the lead named, counted.
3. Yes: pass or fail of the suites.
4. Not zero-valued.
5. Yes, quoted.
6. One mechanism.
7. Not a policy question.
8. None.

## Gate

The runs above.

## Not fixed

Earlier in this session one `test:web` run failed loading `echo_worker_test`
with the split in place, at a load of about 11; at the loads measured here it
did not recur. Heavy load can still make a lone Chrome suite slow to load.

## Links

Leads `../backlog/B-215-the-chrome-suites-fail-differently-every-run.md` and
`../backlog/B-196-the-web-worker-suite-flakes-at-load.md` closed.
Lens `../lenses/RPC-26-the-gate-floor-nobody-chose.md` -- `applied: [..., 702]`.
