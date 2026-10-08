---
status: closed (round 715)
round: 714
commit: 0f167865
paths: [packages/transport/rpc_dart_http/lib/src/rpc_http_responder_transport.dart, packages/transport/rpc_dart_http/lib/src/rpc_http_server.dart]
probe: .dart_tool/probe/audit_h1/cancel.dart
reason: "measured — found by the http1 audit after round 710"
---

# B-265 — an h1 client cancel never reaches the server

## Seen

A server stream that yields slowly and never ends, cancelled by the client
after 300 ms, no deadline, maxActiveStreams 4:

```
call 0..3 cancelled by client
after 2s idle: handlers active=4 finished=0, pendingRequests=4
fresh unary: UNAVAILABLE (HTTP 503)
```

The caller aborts its HTTP request; shelf gives the server no signal that the
connection closed, and the response is not written until the handler ends.
The README says "Cancelling a call aborts its HTTP request", which reads as if
the server stops too.

## Why it matters

Any client, by omitting a deadline and cancelling, holds a server slot for
good; `maxActiveStreams` of them make the server answer 503 to everyone.
http1 is documented as unary-only, which narrows it to endpoints that expose
streaming methods over http1 anyway.

## What a round owes this

The owner's call: (a) a server-side cap on call duration when the caller sends
no deadline (a policy field, new API); (b) watch the underlying connection
where the server is `RpcHttpServer` on dart:io rather than any shelf adapter;
(c) document that streaming methods over http1 need a deadline.

## Owner decision

Owner, 2026-10-08: document it. The rpc_dart_http README now says a cancel stays on the caller's side and streaming calls need a deadline (round 715).
