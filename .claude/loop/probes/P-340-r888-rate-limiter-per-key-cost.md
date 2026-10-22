---
file: packages/core/rpc_dart/.dart_tool/probe/r888_ratelimiter/probe.dart
round: 888
commit: 1631f3af
paths: [packages/core/rpc_dart/lib/src/resilience/rate_limiter.dart]
status: stale (6967b453)
promoted: no — the defect is a per-request cost, and a timing assertion would be a wall-clock flake (cf. audit_frame_reassembly_linear). Correctness of the new store is guarded by test/audit/audit_rate_limiter_colliding_keys_test.dart
---

# P-340 — r888 rate limiter per key cost

## Measures

Microseconds per request through `RpcRateLimiter.interceptUnary`, with the
per-key store held at `maxTrackedKeys`, over three key patterns:
- a repeating hot key (control),
- a fresh distinct key each request (the LRU eviction path, B-308),
- a fresh key each request from a set that all share one `String.hashCode`
  (the collision path).

cap=20000, 2000 requests. Before the salt: control 1.04, distinct 2.66 (2.6x),
collide 230.49 (222x). After: collide 1.55 (1.3x), distinct 2.63.

## Control

The repeating hot key: no eviction, no new node, the same counter every
request. The distinct arm is itself a control for the collide arm — same
rotation, keys that do not share a hashCode — so the 222x is the collisions,
not the rotation.
