---
round: 234 — where it was paid for
class: bench
cost: three WITNESS tests and two GUARD groups green for seven rounds (217-233) while the common path stayed broken; the defect found only by driving the drop from the other side
paths: [packages/transport/*/lib/**, packages/core/rpc_dart/lib/src/resilience/**]
commit: c327a2ce
status: active
---

# L-06 — Test the drop the PEER starts, not the one you call

Rounds 217 and 224 fixed stream-id collisions across a reconnect and pinned the
fix with five tests, every one of which calls `reconnect()` or
`forceReconnect()` itself — the one path where this side is in control and can
read its state before tearing anything down. The real event is the opposite:
the peer goes away, the transport closes ITSELF to report it, and anything that
close destroys is already gone. Ids went 1 then 3 on the path the tests drove
and 1 then 1 on the path they did not, with the same rig and the same code.

**When a lifecycle event can be initiated from either side, both are separate
paths and only one of them is convenient to test.** Write the inconvenient one:
kill the socket, close the peer's end of the pair, drop the process. It is one
extra line in the fixture and it is where the state has already been thrown
away.
