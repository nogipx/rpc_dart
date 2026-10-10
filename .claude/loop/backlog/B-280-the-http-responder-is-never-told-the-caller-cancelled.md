---
status: awaiting owner
round: — (not re-measured by a round; measured by the conformance matrix)
commit: 91ec33ea
paths: [packages/transport/rpc_dart_http/lib/**]
probe: none — packages/test/rpc_dart_conformance/test/i6_cancel_reaches_responder_test.dart and i5_resources_return_test.dart, the KNOWN FAILING http cells
reason: owner decision — rpc_dart_http's README documents that a cancel does not reach the handler; invariants I-5 and I-6 say it must
rank: 12
---

# B-280 — the http responder is never told the caller cancelled

Found by the conformance matrix (I-6 and I-5).

```
I-6 http, 5 cells: the handler of call N never reported "cancelled" within 1000 ms
I-5 http, 4 callerCancels cells and the 40-call cell:
  never reported "disposed" within 2000 ms
```

The handler, its call scope and its timer outlive a cancelled call. B-140
(closed, round 536) stopped the caller's side; the responder is still not
told. The README of rpc_dart_http says this is how the transport behaves.

**The question for the owner:** do I-5 and I-6 hold for http (then this is an
S2 defect for a round), or is http exempt (then the invariants' `across:`
needs a stated exception, written by the owner)?

## Owner decision

—
