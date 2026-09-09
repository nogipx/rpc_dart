---
status: closed (round 190)
round: — (not re-measured)
commit: 5bf4d34e
paths: [packages/core/rpc_dart/lib/**, packages/transport/rpc_dart_websocket/lib/**]
probe: —
reason: "decided by the owner: a policy violation fails the call, the connection lives, plus a cap of 256"
---

# B-07 — Owner decision: `closeOnProtocolError` defaults to `false`

A policy violation fails the CALL and the connection lives on. The flag still
works when it is set explicitly.

Paired with the cap `_maxPolicyViolations = 256`: "one bad frame must not end
the connection" does not mean "a peer may grind forever" — 200k violating frames
cost a websocket server 100 MiB with the attacker still connected.

## Owner decision

closeOnProtocolError defaults to false
