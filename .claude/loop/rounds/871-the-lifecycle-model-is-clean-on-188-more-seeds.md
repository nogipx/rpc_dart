---
round: 871
verdict: CLEAN
packages: [rpc_dart, rpc_dart_http2]
lens: RPC-21
bench: none — the lifecycle model is a test, run here on seeds the gate does not run
commit: yes
release: none
---

# Round 871 — the lifecycle model is clean on 188 more seeds

## Target

Rounds 853-870 changed how calls end on every shape (a failure closes the
caller's response, pumps stop at `isAnswered`, the bidi bridge aborts on a
local error, http2 refusals and sends after the peer's end). The config's
stateful-sequence detector, `lifecycle_model_test.dart`, runs only seeds
1-12 in the gate, and found B-283 there. RPC-21 (drive the lifecycle):
sequences the gate never generates.

## Hypothesis

Random operation sequences on one connection keep the model's properties
on every member after these rounds. Fails if any seed's cell fails.

## Before

```
seeds 13-60:   +245 ~49   all passed (the ~ are the wasm member)
seeds 61-200:  +705 ~141  all passed
```

## Mechanism

None found.

## After

n/a.

## Canary

n/a — no fix. Round 870's switched-off fix failing the pinned cell is the
model's control.

## Gate

No change: `_seeds` was widened for the run and put back to 1-12.

## Siblings

—

## Not fixed

—

## Links

Lens `../lenses/RPC-21-drive-the-lifecycle-twice.md`. Negative
`../checked/C-96-the-lifecycle-model-is-clean-on-188-more-seeds.md`.
Round `870-a-request-after-the-servers-end-keeps-its-status-on-http2.md`.
