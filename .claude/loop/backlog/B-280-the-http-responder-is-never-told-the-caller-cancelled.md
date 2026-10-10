---
status: closed (round 804)
round: — (not re-measured by a round; measured by the conformance matrix)
commit: 91ec33ea
release: changelog
paths: [packages/transport/rpc_dart_http/lib/**]
probe: none — packages/test/rpc_dart_conformance/test/i6_cancel_reaches_responder_test.dart and i5_resources_return_test.dart, the KNOWN FAILING http cells
reason: "FIXED in round 804 as decided: under RpcHttpServer the connection's close cancels the handler, ~2.1 s after the cancel here; the bound question is B-284. Previously: owner decision — rpc_dart_http's README documents that a cancel does not reach the handler; invariants I-5 and I-6 say it must"
rank: 2
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

Owner, 2026-10-10: I-5 and I-6 hold for http; fix it. This replaces the
B-265 decision of 2026-10-08 (document that a cancel stays on the caller's
side), so the README line round 715 wrote goes when the fix lands.

The constraint, from B-265: shelf gives the server no signal that the
connection closed, and the response is not written until the handler ends.
The route B-265 named is watching the underlying dart:io connection where
the server is `RpcHttpServer`, not any shelf adapter; its cost is not
measured. A responder mounted on a foreign shelf server may stay out of
reach, and the round says so rather than skipping the cells silently.
