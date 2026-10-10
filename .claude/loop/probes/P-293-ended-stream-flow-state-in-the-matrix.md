---
file: packages/test/rpc_dart_conformance/test/i5_resources_return_test.dart
round: 802
commit: e1899b97
paths: [packages/core/rpc_dart/lib/src/rpc/transports/**]
status: valid
promoted: packages/test/rpc_dart_conformance/test/lifecycle_model_test.dart
---

# P-293 — the server's per-stream flow-control state after calls that end by deadline, failure or a late frame

The conformance matrix is the bench: the I-5 rows "after a call that
deadline / handlerFails" and "after many calls on one connection", and the
lifecycle model's seeds and its pinned "send after the handler failed,
response paused". Each reads the server transport's `flowControlStateSizes`
2 s after the calls end. Run from the package directory:
`fvm dart test test/i5_resources_return_test.dart test/lifecycle_model_test.dart`.

A standalone core probe (`packages/core/rpc_dart/.dart_tool/probe/r802_flow_state_after_late_answers.dart`,
unary past its deadline and the pinned bidi sequence, over `pair` and
`memoryPair`) read 0 entries with the fix switched off as well as on. It
does not see the defect and is not this bench.

## Measures

Entries in the server's per-stream flow-control maps (`fc.*`) left after the
calls have ended, against the baseline before them.

## Control

The same rows on the same members with endings that do not race a late
frame (`completes`), and the same endings on members not built on the
channel transport (http, http2), stay at baseline. Before the fix:

```
isolate | unary deadline         fc.sendCredit 0->1  messageCredit 0->1  advertised 0->1
isolate | serverStream deadline  1->2 each
isolate | 40 calls               sendCredit 0->3  messageCredit 0->3  advertised 0->5
channel | 40 calls               advertised 0->2
model isolate seed 5             0->5 each        (5 calls, 5 entries)
model channel/isolate pinned     pendingGrant 0->1  pendingMessageGrant 0->1
isolate | unary completes        0 (control)
http, http2, every row           0 (control)
```
