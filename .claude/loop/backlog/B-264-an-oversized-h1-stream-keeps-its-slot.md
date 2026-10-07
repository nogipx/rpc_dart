---
status: closed (round 714)
round: 714
commit: 0f167865
paths: [packages/transport/rpc_dart_http/lib/src/rpc_http_responder_transport.dart]
probe: .dart_tool/probe/audit_h1/oversize.dart
reason: "measured — found by the http1 audit after round 710"
---

# B-264 — an oversized h1 stream keeps its slot

## Seen

maxMessageLengthBytes 64 KiB, maxActiveStreams 4, four calls to a server
stream that runs until cancelled, no deadline:

```
call 0..3: RESOURCE_EXHAUSTED (response exceeds the limit)
after 2s idle: handlers active=4 finished=0, pendingRequests=4
fresh unary: UNAVAILABLE (HTTP 503)
```

## Owner decision

None needed: one client fills the server's slots for good.
