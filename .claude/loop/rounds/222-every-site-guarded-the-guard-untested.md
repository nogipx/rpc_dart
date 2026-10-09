---
round: 222
verdict: CLEAN
packages: [rpc_dart, rpc_dart_http2, rpc_dart_websocket, rpc_dart_isolate, rpc_dart_http]
lens: RPC-13
bench: none — the detector is a grep plus reading; the ablation is the instrument
budget: probes 0/3, canaries 0/3
review: self — the session forbids the Agent tool unless the user asks; the `loop.py review` prompt was answered against the record, and Q4 is what produced this round's finding rather than its verdict
commit: no
---

# Round 222 — every site guarded, and the guard untested

## Target

Not B-17: declined for the fourth time, its decision still measured
unimplementable and its replacement still with the owner. Recorded, not skipped.

RPC-13 — an unhandled async error is fatal to the isolate — which the curate
pass left at the head of the re-measurement queue. Its sweep is `off-journal`
with no sha, so it can never age out on its own, and rounds 206-212 added
several new `unawaited(...)` calls to exactly the paths it covers.

## Hypothesis

One of the futures those rounds abandoned runs user code with no error handler,
and in Dart that kills the whole isolate.

## Before

```
unawaited( across the five transport packages       ~85 sites

of those, on the paths the detector names — dispatch, lifecycle
callbacks, accept loops — every one read and found guarded:

  responder_pipeline _detached / _detachedDispatch   .catchError
  responder_pipeline 1479, 1533 (bidi dispatch)      try/catch inside
  http2_responder 433 (error trailer)                try/catch inside
  http2_responder 638 (round 208's refusal)          .catchError
  http2_caller (round 208's reset)                   .catchError
  http2_server 247 (GOAWAY fan-out)                  .catchError
  websocket_io_connections 234 (upgrade refusal)     .catchError
  channel_transport 1043/1053/1077/1103 (grants)     try/catch inside
                                                     _fcSendGrant
```

Everything rounds 206-212 added is guarded, which is the question this
re-measurement existed to answer.

## Mechanism

Nothing is wrong. The class is also visibly understood in the code: the
`_refuse` path says in as many words that "throwing here would land in the root
zone and kill the isolate", and `_detached` carries the production story that
paid for it — a client abandoning a coalesced blob download, and "both replicas
exited 255 within hours of each other".

## After

n/a — nothing changed. `git diff` empty, `analyze` green.

## Canary

n/a — no fix. What was run instead is the ablation Q4 demands, and **it produced
this round's finding**: with `_detached`'s `.catchError` removed, so that a
failing detached future reaches the root zone, the core suite still passes.

```
  _detached guard removed, core suite:   +1395 ~1, All other tests passed
```

## Gate

No code changed — the ablation was reverted in place, `git diff` is empty and
`analyze` is green. The ablated run itself is the measurement above, not a gate
result; the gate proper is the one HEAD passed at round 212.

## Not fixed

**The most load-bearing guard in this lens has no witness.** `_detached` exists
because a client hanging up killed two production replicas, and removing it
changes nothing any test can see. So the sweep's conclusion — every site is
guarded — is true today and unprotected tomorrow: a refactor that drops one of
these `.catchError`s ships green.

That is not "coverage for coverage's sake", which the config's bar rules out. It
is a guard against process death with a production-observed failure mode and
zero regression coverage, and the ablation is the measurement that says so.

Writing the witness is a round of its own, because the honest version is
awkward: `_detached` is private and its callers are teardown paths, so the test
has to drive a real cancellation whose cleanup throws and then assert the
process survived — and asserting "the isolate did not die" from inside that
isolate needs a subprocess, the shape `close_releases_the_isolate_test` already
uses in rpc_dart_isolate. Filed as B-20.

## Links

Lead `../backlog/B-20-detached-guard-has-no-witness.md` — new.
Lens `../lenses/RPC-13-unhandled-async-error.md` — `applied: [222]`, sweep
refreshed to b8d934a2 with the site list and the untested-guard finding.
Round `221-the-sweep-that-could-not-see-a-hang.md` — the same Q4 discipline, and
there the ablation confirmed the instrument; here it indicted it.
