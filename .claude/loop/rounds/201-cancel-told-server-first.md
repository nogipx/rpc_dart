---
round: 201
verdict: FIXED
packages: [rpc_dart]
lens: RPC-15
bench: none
budget: probes 0/3, canaries 0/3
review: self (record migrated into the schema; the round itself had no review)
commit: yes
---

# Round 201 — a cancelled call told the server before telling itself

## Target

RPC-15 — re-measure the loop's own record. The record about the error-type split
on a closed transport claimed the question had dissolved; re-running it added a
row the table had never had — wasm — and that row turned out to be the defect.
Three deferrals re-measured in one run, all three recorded wrongly.

## Hypothesis

Closing the caller during a server stream gives the same observable result on
every transport.

## Before

```
what the consumer sees when the caller is closed:

  websocket, isolate -> RpcCancelledException: Endpoint closed
  wasm               -> items=11 events=[DONE]   <- a clean end
```

## Mechanism

`_setupCancellationMonitoring` did `await _sendCancellationToServer(reason);` — a
network round trip — and only then `addError` on the local controllers. A send
that never completes carries the local error away with it; the `try` around it
catches a THROW, not a HANG. A stream that ended cleanly is indistinguishable
from one that finished, so the consumer processed a truncated stream and moved
on — silent data loss. Reachable only on wasm: only there does the bridge's send
wait for the platform channel's reply, and `close()` tears the transport down
right under that await.

## After

```
  wasm -> items=11 events=[ERROR RpcCancelledException, DONE]
```

## Canary

It worked on the second attempt, and that matters. The FIRST canary was wrong:
hoisting `_isActive = false` above the send made `_sendCancellationToServer`
return at once, the await completed, and the witness PASSED. The honest canary —
send first, while still active — fails it with `ended as [DONE]` and leaves the
other seven green.

The witness POLLS the observation rather than sleeping: a flat 4 s failed twice
under load average 16 and passed on its own — it waits for something the
CONSUMER notices, and load delays the observation, not the production.

## Gate

reuse lint, melos analyze, format:check, test:unit --no-select, test:wasm,
analyze:native (both halves) — PASS; the core and transport suites on dart2js
(407); devices: iPhone 16 / iOS 18.6 (17/17) and emulator-5554 / Android 11
(15/17, 2 platform skips).

## Not fixed

Nothing

## Links

Lens `../lenses/RPC-09-deadline-below-write.md` — the same shape ("await the
write, then report locally") somewhere else; closed the lead
`../backlog/B-08-decision-closed-transport-error-split.md`.
