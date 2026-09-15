---
file: packages/transport/rpc_dart_websocket/.dart_tool/probes/ws_collect_server.dart + test/browser_client_stream_delivery_test.dart
round: — (2026-09-15, from a consumer's incident)
commit: bb8548939524ee67a53dcc5339d15f772e3f032e
paths: [packages/transport/rpc_dart_websocket/lib/**, packages/core/rpc_dart/lib/src/rpc/transports/channel_transport.dart]
status: valid
---

# P-51 — does a client-stream lose a message on the browser WebSocket?

The one combination the suite never had: **dart2js in a real browser, a real
`WebSocketChannel.connect`, and a real dart:io server.**
`websocket_client_stream_no_duplicate_test.dart` covers the duplicate half over
dart:io on both ends; `websocket_web_smoke_test.dart` runs on dart2js but over
an in-memory channel pair. B-44's reports come from precisely the gap between
them.

```
cd packages/transport/rpc_dart_websocket
fvm dart run .dart_tool/probes/ws_collect_server.dart 9531     # shell 1
fvm dart test test/browser_client_stream_delivery_test.dart -p chrome
```

The handler answers `count|head,head,…` of what it received, so every assertion
is on the response — no control channel, nothing trusted but the wire. Traps
paid for:

1. **The accept loop needs `onError` + `cancelOnError: false`.** Without it one
   socket ending badly kills the listener and every later connect is refused —
   which reads exactly like the transport defect being hunted. It cost one wrong
   reading before the arm was fixed.
2. Chrome's first launch times out in `BrowserManager._start` on this machine
   about half the time. Re-run; it is the harness, not the code.
3. The messages are 256 KiB, so only the first 12 characters identify them.

## Arms

Five, in one browser session: one call of 8 small messages; one of 8 × 256 KiB;
**four concurrent calls** of 8 × 256 KiB on one connection (the consumer's
upload concurrency, which nothing else in the suite does); twenty sequential
calls on one connection; ten COLD connections with one call each — the condition
the consumer's own notes blame ("the first ~2 streams after a cold connect").

## What it showed

**Nothing.** 36 calls, every message delivered once, in order, on every arm.

That is a negative worth keeping, because of what it eliminates. Together with
`client_stream_delivery_test.dart` (the same shapes on the VM and on dart2js
over an in-memory pair, also clean) the remaining suspects for B-44 are: the
pinned 6.0.0 the consumer actually runs (26 commits behind this bench), the TLS
+ reverse-proxy hop in front of their server, Electron's renderer rather than
plain Chrome, and ~1 MiB encrypted payloads.

## Next use

Pin BOTH sides at the consumer's ref (`55159adf`) and re-run. If it reproduces
there, B-44 is already fixed upstream and the consumer needs a bump; if it does
not, the remaining difference is the network path, and the bench should grow a
proxy arm rather than more shapes.
