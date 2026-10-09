---
round: 760
verdict: INCONCLUSIVE
packages: [rpc_dart_isolate]
lens: RPC-15
bench: none — the failure did not occur in 7 runs, so no arm could see it
commit: yes
release: none
---

# Round 760 — the web flake does not come back

## Target

B-270, rank 1 and the only fresh lead: `melos run test:web` lost its first
chrome test twice in about ten runs during rounds 746-747, and the text after
`[E]` was never kept. The lead's instruction is to run unfiltered and keep it.
B-267 not taken.

## Hypothesis

The first chrome invocation fails intermittently, more often under load (one
of the two failures ran beside the websocket suite).

## Before

```
  test:web, unfiltered, full log per run
    idle machine (2 earlier this session, 3 now)   5 runs   0 failures
    beside the websocket suite                     2 runs   0 failures
      (both websocket runs 295/295: the load was real)
  echo_worker_test.dart, every run:  "real Web Worker unary + server-stream
                                      RPC round-trip" passed
```

## Mechanism

Unknown: the failure did not occur, so its text is still not captured.

## After

n/a.

## Canary

n/a.

## The verdict questions

1. No control is possible without a failure to contrast.
2. No: nothing failed, so the runs cannot show they would see it. That is
   why the verdict is INCONCLUSIVE and not CLEAN.
3. In the gate's own output, unfiltered.
4. Seven zeros; the mechanism's text has never been seen.
5. n/a.
6. n/a.
7. INCONCLUSIVE: what was tried is listed above and in B-270.
8. B-267 left open; nothing dismissed.
9. None.
A1. n/a.
A2. Load was varied: idle against beside the websocket suite.
L1. n/a.

## Gate

n/a — no code change.

## Not fixed

B-270 stays open, reason `bench`, with the 7 runs added and the command that
keeps the full log.

## Links

Lead `../backlog/B-270-the-web-gate-loses-its-first-browser-test.md`.
Lens `../lenses/RPC-15-remeasure-own-record.md` — `applied: [..., 760]`.
