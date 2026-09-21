---
status: open
round: 422
commit: 5674789e
paths: [packages/transport/rpc_dart_websocket/lib/src/websocket_caller_transport.dart, packages/transport/rpc_dart_websocket/lib/src/ws_open_stub.dart]
probe: none — READ, found while answering "does websocket need keepalive?"
reason: risk — the WebSocket API in a browser has no ping, so the fix is an application-level heartbeat with its own wire cost, and the owner has not asked for one
---

# B-71 — a browser WebSocket client cannot detect a half-open path

WebSocket keepalive is native: `dart:io`'s `WebSocket.pingInterval` pings every
interval and CLOSES the socket itself if no pong returns in one. That is why
there is no hand-rolled loop on this transport, and why round 422's
`startHttp2Keepalive` is http2-local — HTTP/2 needs the loop because
`package:http2` exposes `ping()` and does not act on a missing ACK.

On the web there is no equivalent. The browser owns ping/pong and exposes
neither, so the parameter is accepted and DROPPED. The code already says so, at
`websocket_caller_transport.dart:123`:

> *"Accepted and IGNORED on the web: browsers run ping/pong inside the browser"*

and `ws_open_stub.dart:34` takes `pingInterval` only for signature parity.

## What that costs

A browser client on a half-open path — the peer gone, the socket still "open"
to the runtime — has **no liveness signal at all**. It learns only when a call
reaches its own deadline, and a caller that set none waits forever. Every other
transport detects this:

```
  transport            half-open detected by
  websocket (VM)       WebSocket.pingInterval, native
  websocket (web)      NOTHING
  http2                startHttp2Keepalive, this library's own loop
  isolate              the port closing
```

The asymmetry is invisible from the API: the same
`RpcWebSocketCallerTransport.connect(..., pingInterval: ...)` call silently does
one thing on the VM and nothing in a browser.

## Why it is filed rather than fixed

The only route is an application-level heartbeat — an RPC the client sends on a
timer — and that is a design decision with costs the owner has not been asked
about:

- it puts traffic on the wire that the VM path does not need, so the two
  platforms stop behaving the same in the other direction;
- `RpcEndpointPingExchange` already exists and could carry it, but nothing
  currently drives it on a schedule;
- a heartbeat that fires while a long call is in flight competes with it for
  the connection window.

Round 224's rule applies: a capability a transport cannot provide should be
refused at the type level rather than accepted and ignored. The narrow version
of this fix is to make the web path REFUSE a non-null `pingInterval` instead of
dropping it, so the gap is at least loud — that is a one-line change and a
breaking one for anyone passing it today.

## Owner decision

—

Three shapes, and the cheapest is not obviously wrong:

1. **Leave it, document it.** The comment exists; the transport's public doc
   does not say it.
2. **Refuse it loudly** on the web path, so the silent drop becomes an error.
   Breaking for callers that pass `pingInterval` and run on both platforms.
3. **An application-level heartbeat** driven by the caller transport, web only,
   with the wire cost above.
