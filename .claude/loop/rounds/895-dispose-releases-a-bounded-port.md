---
round: 895
verdict: FIXED
packages: [rpc_dart_websocket]
lens: RPC-25
bench: P-347 — new
commit: yes
severity: S1 — "a call, connection or shutdown that hangs with no bound"
release: changelog
---

# Round 895 — dispose releases a bounded port

## Target

RPC-16's server side, after rounds 890-891 closed the client's: does a
server's stop reach what is in flight? Taken on the websocket server (the
owner's priority after core), set up as its README's `serve()` example does:
`bindRpcWebSocketHttpServer`, and the returned HttpServer not kept. The
journal had nothing on a stop during an upgrade (P-164, a connection accepted
mid-shutdown, is stale).

## Hypothesis

A connection still sending its upgrade request holds the shutdown, or the
port, after `RpcWebSocketServer.dispose()`. Fails if the port is released and
the process exits at once.

## Before

P-347 (`r895_dispose_server/probe.dart` via `run.py`):

```
idle     bindRpcWebSocketHttpServer, no client      port still accepting   still running 38 s after dispose (killed)
pending  same, a client mid-upgrade                  port still accepting   still running 38 s (killed); the half-upgraded socket itself closed within 2 s
plain    HttpServer.bind, no client (control)        port released         exit 35 ms
```

The hypothesis was wrong about its cause: the connection in flight is closed.
What holds is the PORT, with no client at all.

## Mechanism

RPC-25, one abstraction implemented twice: `_BoundedHttpServer` wraps the
`HttpServer.listenOn` server that `bindRpcWebSocketHttpServer` returns, and
its `close()` releases the header-bounded socket, because `listenOn` leaves a
socket it was given open. But `dispose()` lets go of the server by cancelling
its subscription, which dart:io answers by closing the HttpServer -- and the
wrapper passed `listen` straight to the inner server, so the socket under it
stayed bound. `HttpServer.bind` owns its socket and releases it on the same
cancel. The README's `serve()` keeps no handle, so nothing else could close it.

## After

`_BoundedHttpServer.listen` hands out a subscription of its own whose cancel
cancels the inner one and closes the socket. P-347 after: port released in
all three arms; `idle` exits in 14 ms, `plain` in 44 ms (`pending`'s 2 s is
the probe's own 2 s wait).

## Canary

`dispose_releases_a_bounded_port_test.dart`: `listen` switched back to passing
straight through: WITNESS "dispose releases the port of a
bindRpcWebSocketHttpServer" red, "Expected: false Actual: <true> the port is
still bound after dispose()". GUARDs "dispose releases the port of a plain
HttpServer" and "the port serves until dispose" green both ways. Restored:
`+3`.

## Gate

`melos run analyze`, `test:unit:quiet --no-select`, `format:check`,
`license:check`, `api:check`: green. The change is in the dart:io half only;
no web path is touched.

## Siblings

- websocket: fixed here (P-347).
- http: clean — probe `packages/transport/rpc_dart_http/.dart_tool/probe/r895_sibling/probe.dart`:
  `RpcHttpServer` binds the same `RpcHeaderBoundedServerSocket` but owns it and
  closes it in both branches of `stop()`; port released and exit in 16 ms
  (`stop()`) and 58 ms (`stop(drainTimeout:)`).
- http2: n/a — `RpcHttp2Server` binds and owns its own socket and hands out no
  server object the application could be left holding.
- isolate: n/a — no listening port.
- wasm: n/a — no listening port.
- channel: n/a — no listening port.
- responder: fixed here — the server side is where the port lives.
- caller: n/a — a caller binds no listening port.
- (not a group member) socket: n/a — `RpcSocketServer` owns its socket the
  same way as http2.

## Not fixed

`stop()` (without dispose) keeps the subscription by design so `start()` can
resume, and so keeps the port, as it does over `HttpServer.bind`; not a
defect.

## Links

RPC-25, RPC-16, rounds 890-891, P-164, P-347.
