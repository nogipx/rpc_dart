---
round: — (not re-measured)
commit: d9b96a67
paths: [packages/transport/rpc_dart_http/lib/**, packages/transport/rpc_dart_wasm/lib/**, packages/transport/rpc_dart_websocket/lib/**, packages/transport/rpc_dart_http2/lib/**]
scope: [http, wasm, websocket, http2]
---

# C-28 — Sibling batteries that came back clean

Measured across **rounds 40, 99, 106 and 109**, all off-journal, so `round:`
above carries no number — `lint` reconciles that key against the round files,
and there are none.

The defects this battery found are in
`../lenses/RPC-08-policy-field-single-transport.md`. These are the rows that came
back CLEAN — **do not re-run them.**

**`rpc_dart_http`, round 99.** A client that aborts mid-call does not leak:
handler finishes, `openStreams` 0, `activeResponders` 0, identical to a normal
completion. The handler does run to completion for a client that is gone —
bounded by its own duration, and HTTP/1.1 has no reset signal — which is
ordinary HTTP server behaviour.

**Browser attack surface on `rpc_dart_http`, round 109.** The only transport a
browser can reach directly, and its CORS policy had never been reviewed.
`RpcHttpCorsPolicy` is secure by default (`allowedOrigins: const []` = closed),
throws at construction on `allowCredentials` + `'*'` (deliberately a throw rather
than an `assert`, because `dart run` does not enable asserts), matches origins by
EXACT membership with no prefix or regex, never reflects
`Access-Control-Request-Headers`, and emits `Vary: Origin` only when the response
actually varies. **The CSRF gate holds**, which is the part that matters: CORS
protects an RPC server only while browsers are FORCED to preflight, and that
requires refusing the CORS-safelisted content types. Counting handler
executions:

```
  application/grpc+proto POST   -> 200 / ran     <- control
  text/plain                    -> 415 / 0
  application/x-www-form-urlencoded -> 415 / 0
  GET                           -> 405 / 0
```

Nothing a browser can send without a preflight reaches a handler.

**`rpc_dart_wasm`, round 106 — clean by construction.** It is a thin adapter:
`RpcWasmTransport.fromBridge` returns `RpcChannelTransport.fromChannel(...)`,
which wraps the bridge in `RpcFrameMultiplexedChannel`. Every inbound bound the
channel transports have — frame size, buffer cap, metadata validation, flow
control — therefore applies to bytes coming back from the sandboxed module.
Nothing transport-specific to audit.

**The RESPONDER side of the peer-loss battery, round 40.** Client killed abruptly
mid-call (raw socket destroyed, through a one-hop TCP relay for websocket, since
dart:io will not send close code 1006). Both http2 and websocket: endpoints
released 1 -> 0, per-stream maps at zero, the server-stream handler STOPPED
within ~2 yields, the server survived. A parked unary handler does run to
completion — Dart cannot preempt it — which is expected, not a leak.

**Three asymmetries that are NOT defects.** Do not "fix" them:

- `RpcHttpServer.start()` does not bind; binding is deferred to
  `afterModulesStart()` so contracts are registered first, while its siblings
  listen straight from `start()`. Deliberate and documented — though note
  `IRpcServer.start()` is specified as "Starts the server", so generic code
  against the interface gets a live server for two transports and a dead one
  here. The owner's API call, not a bug to patch blindly.
- The bound port IS exposed on `rpc_dart_http`, as `actualPort` rather than the
  http2 sibling's `port`, so `port: 0` works. A "missing accessor" gap was
  recorded in round 99 before reading the file; it does not exist.
- `RpcChannelTransport.createStream()` does not throw when closed while both
  HTTP callers do. That is a documented choice pinned by three tests — see
  `../lenses/RPC-19-one-flag-two-lifecycle-meanings.md` on the quiet-close
  contract before touching it.

## Control

Each row is one arm of a battery whose OTHER arms found real defects at the same
time — silent truncation on http2, a fatal peer-death path on websocket, a
missing keepalive, a missing drain (all in RPC-08). The instrument demonstrably
detects what it is looking for, so these rows are clean because the behaviour is
correct, not because the battery is blind.
