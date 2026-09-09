---
round: 206 — where it was paid for
class: bench
cost: 1 canary attempt of 3 — the gate canary passed on its first run, and the witness had to be rebuilt from 12 short calls to 1 long stream
paths: [packages/core/rpc_dart/lib/src/rpc/transports/**]
commit: c48a14d8
status: active
---

# L-01 — when a fix has two halves, check whether one MASKS the other's witness

Round 206 shipped a debt ledger (repay the connection pool at teardown) and a
widened gate (meter when EITHER window is configured). Switching the gate off
left every test green, because the ledger repaid the whole stream's debt the
moment the call ended — across 12 short calls the missing gate was invisible.

Canary discipline already says a two-half fix needs two canaries, and that a
canary which unexpectedly passes means the TEST is wrong. What this round adds
is the reason it was wrong and how to fix it: the halves differed in WHEN they
credit, not in whether, so the witness had to remove the other half's
opportunity to act. One stream that never ends — so teardown never comes —
turned the same canary from green into "wedged after 1024 KiB against a
1024 KiB pool".

Before writing a witness for one half, ask what the other half does on that
timeline, and pick a shape where it cannot cover.
