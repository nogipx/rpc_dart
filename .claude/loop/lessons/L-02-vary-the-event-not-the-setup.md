---
round: 207 — where it was paid for
class: bench
cost: 1 probe rebuild of 3 — the first bench varied the handler, so it measured the handler and could not attribute anything to the abort
paths: [packages/transport/rpc_dart_http2/lib/**]
commit: 1d5efdda
status: active
---

# L-02 — when the defect is an EVENT, vary the event, not the setup

Round 207's first bench compared a deaf handler against a draining one and
watched a connection die. True, but useless: the two arms never reached the same
state, so the death could be blamed on the deaf handler as easily as on the
cancel — and a stalled stream holding the connection pool is CORRECT HTTP/2
behaviour, so the deaf arm was partly measuring something that is not a defect.

The rebuild made both arms identical up to the moment of interest — the same
handler, stalled the same way, both confirmed held by a "ping during stall"
that HUNG in both — and varied only how the stalled call ENDED: cancel versus
drain. That reading of the shared state before the split is what makes the
comparison mean anything; without it there is no proof the arms were ever equal.

When the hypothesis is about a transition, build the bench so both arms sit in
the same state, assert that they do, and then apply the two different endings.
