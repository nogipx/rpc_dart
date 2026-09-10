---
round: 269
verdict: RETRACTED
packages: []
lens: RPC-11
bench: none
commit: yes
---

# Round 269 — what `melos run test:wasm` actually resolves

**Filed retroactively in round 271.** This round happened and was committed
(`ada68beb`, third section of that body) but never got a record here, so
`loop.py next` handed out 269 a second time. The text below is that commit's,
condensed; no claim is added. Its central conclusion was **wrong** and round
270 retracted it — read them together.

## Target

The first of B-23's six dossiers, `release_gate_blind_spots`, taken first
because its claims are the ones a command can settle rather than argue about.

## Hypothesis

`rpc_dart_wasm` sits outside the pub workspace, so `melos run test:wasm` may be
validating the PUBLISHED core rather than the local one — which would mean a
core change that breaks the wasm bridge passes the gate green.

## Before

```
rpc_dart_wasm/pubspec.yaml:32   rpc_dart '>=5.0.0 <6.0.0'
dependency_overrides in it      none
workspace membership            not a member
```

Read as: pub resolves the core from pub.dev. Written into `config.md` beside
the command, as a property of resolution rather than a measurement that ages.

## Mechanism

Claimed: no local link exists, so the constraint is honoured against pub.dev.

## After

n/a — no code changed. Also sized B-23's dossier half so the next round starts
from numbers: 1653 lines across six notes, eighteen times the architecture half,
and a different KIND of content (measurements and verified-clean lists, which
belong in `checked/` and lens Evidence rather than in `docs/`).

## Canary

n/a

## Gate

n/a — documentation only.

## Not fixed

The conclusion itself. See round 270.

## Links

RPC-11, B-23.
