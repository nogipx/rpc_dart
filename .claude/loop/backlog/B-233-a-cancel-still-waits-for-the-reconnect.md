---
status: closed (round 628)
round: 628
commit: 2ad569c5
paths: [packages/core/rpc_dart/lib/src/resilience/retry_interceptor.dart]
probe: P-158
reason: "FIXED in round 628: the token is re-read after the backoff; 3106 ms and one reconnect became under 1500 ms and none. Previously: bench — round 623 made the backoff end on cancel, but the loop then awaits the reconnect before re-checking the token, so the cancel waits out a reconnect the abandoned call started"
---

# B-233 — a cancel still waits for the reconnect

Found by the independent audit of 2026-10-02 (lifecycle), reproduced before
filing. The remainder of B-129 item 13.

## Measured

`audit_lifecycle_retry_cancel_reconnect.dart`, UNAVAILABLE on an unhealthy
transport, cancel at 100 ms during a 2 s fixed backoff:

```
reconnect 3000 ms, cancel      3111 ms  reconnects 1  CANCELLED
reconnect 0 ms,    cancel       102 ms  reconnects 1  CANCELLED
reconnect 3000 ms, no cancel   5005 ms  reconnects 1  UNAVAILABLE
```

## Fix direction

Check the token after `_backoff` returns and before
`_reconnectIfConnectionIsGone`.

## Owner decision

—
