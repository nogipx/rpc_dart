---
round: 628
verdict: FIXED
packages: [rpc_dart]
lens: RPC-16
bench: P-158 — reused
budget: probes 1/5, canaries 1/5
commit: yes
release: changelog
severity: S2
---

# Round 628 — the reconnect nobody asked for

## Target

B-233, the remainder of B-129 item 13 that round 623 left: the audit of
2026-10-02 found a cancel during the retry backoff still waits for a reconnect.

## Hypothesis

`_backoff` returns on the cancel, and the loop then awaits
`_reconnectIfConnectionIsGone` before the next attempt reads the token.

## Before

```
transport down, reconnect takes 3 s, 2 s fixed backoff, cancel at 100 ms
  cancelled after 3106 ms, 1 reconnect started
```

## Control

The same call without a cancel: UNAVAILABLE after the backoff plus the reconnect
(`>= 5000 ms`, 1 reconnect). With an instant reconnect the cancel ends in
`~100 ms`, so the 3 s is the reconnect.

## Mechanism

RPC-16's shape across two awaits: the token was checked inside the first
(`_backoff`) and not before the second.

## After

The loop re-reads the token after the backoff and goes straight to the next
attempt, which fails CANCELLED at once: under 1500 ms, 0 reconnects. Round 623's
two arms and the new control pass.

## Canary

The before line is the same test without the check.

## Gate

`analyze` and `format` on rpc_dart green, `melos run test:unit` green (exit 0).
No web arm: the change is a token read between two awaits.

## Not fixed

A cancel that lands DURING the reconnect still waits for it to return; the
reconnect is the transport's and takes no token.

## Links

Lead `../backlog/B-233-a-cancel-still-waits-for-the-reconnect.md` — closed.
Bench `../probes/P-158-does-a-cancel-cut-the-retry-backoff.md` — reused.
Lens `../lenses/RPC-16-check-before-await.md` — `applied: [..., 628]`.
Test `packages/core/rpc_dart/test/resilience/a_cancel_cuts_the_retry_backoff_test.dart`.
