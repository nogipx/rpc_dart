---
refines: U-17
paths: [packages/transport/*/lib/**, packages/core/rpc_dart/lib/src/resilience/**, packages/core/rpc_dart_framework/lib/src/rpc_isolate_module.dart, packages/notify/*/lib/**]
applies: opening a connection takes several stages (TCP, TLS, an upgrade, a protocol preface or SETTINGS, a ready message) and a timeout or a default guards the open
breaks: a hang that never ends: connect() or reconnect() waits forever on a peer that answered the first stage only.
applied: [754, 755]
status: confirmed (round 754)
rank: 6
---

# RPC-28 — A connect timeout that ends a stage early

## Shape

A `connectTimeout` is handed to the call that opens the socket, so it ends
when TCP (or TLS) is up. The stages after it, the ones that make the
connection usable, wait on the peer with no bound: the HTTP/2 SETTINGS
frame, the WebSocket 101, an isolate's ready message, a handshake RPC. Or
the timeout exists and its DEFAULT is null, so the bounded path is opt-in.

## Detector

Every open path, by text (dart-runner has no search for parameters):

    grep -rln "connectTimeout\|connectionTimeout\|Socket.connect\|SecureSocket.connect\|Isolate.spawn" \
      packages --include='*.dart' | grep /lib/

13 files at round 765: http2 caller transport, websocket caller /
`ws_open_io` / `connectBounded`, isolate transport and worker policy,
`RpcClientConnection`, `RpcIsolateModule`, `rpc_notify_redis`. For each,
list the stages in order and mark which one the timer's future spans, and
what the default is when the caller passes nothing.

## Ask

A server that completes stage k and then stays silent, k for each stage in
turn: does the open fail within the timeout, with the timeout's error? Run
it once with the timeout passed and once with it omitted, since an omitted
default and an explicit null are different arms.

## Evidence

- **Round 754** — http2 `connectTimeout` covered the socket only; a peer
  that never sent SETTINGS held `connect` open. Fixed with a timer from the
  socket to `onInitialPeerSettingsReceived`.
  `../rounds/754-a-silent-h2-peer-reads-online.md` (filed under RPC-08).
- **Round 755** — websocket `connect` had `connectTimeout` with a null
  default: an upgrade that never answered hung the caller unless the caller
  knew to pass one. Default set to 30 s. A probe that passes an explicit
  null measures a different arm from one that omits it.
  `../rounds/755-websocket-connect-had-no-default-bound.md` (filed under
  RPC-08).
