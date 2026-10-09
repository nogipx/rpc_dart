---
round: 782
verdict: DEFERRED
packages: [rpc_dart_websocket, rpc_dart_http]
lens: RPC-18
bench: P-277 — new
commit: yes
release: none
severity: S1
---

# Round 782 — unfinished request headers are held unbounded

## Target

The network-audit skill's `known websocket` sweep, KV-WS-05 (handshake
resource exhaustion). KV-WS-01, -02 and -04 were read off current code
first: permessage-deflate is opt-in and its doc in `ws_open_io.dart` names
the bomb; the caller's bounded open and `allowedOrigins` exist. No record
measured a request whose header block never ends (`loop.py find 'header
flood upgrade request'`, `'incomplete request headers held'`); B-27 and
P-35 are about upgraded or idle sockets.

## Hypothesis

dart:io holds an unfinished request header block with no deadline, and
nothing counts connections that have not produced a request, so memory
held is the attacker's bytes times their connection count.

## Before

P-277, 300 connections, 900 KiB of headers each, never ended:

```
  server                peak rss    footprint 20s / 110s   closed after 140s
  websocket (io)        +313 MiB    318 MB / 318 MB        0 of 300
  RpcHttpServer         +311 MiB    -                      0 of 300
  control (0 KiB)       +3 MiB      -                      0 of 300
  one non-stop flood    +6 MiB      -                      cut at ~3 MiB sent
```

Probe: `packages/transport/rpc_dart_websocket/.dart_tool/probe/header_hold_attacker.py`

## Mechanism

dart:io's `HttpServer` buffers the header block until it ends, caps a single
block, and applies `idleTimeout` only between requests. A connection that
has not finished its first request produces no `HttpRequest`, so neither
`rpcWebSocketConnections` nor `RpcWebSocketServer.maxConnections` nor
`RpcHttpServer` sees it.

## After

n/a.

## Canary

n/a.

## The verdict questions

1. Yes: the control differs only in `kib` (0 against 900).
2. Yes: +3 MiB against +313 MiB.
3. Server process: its own RSS, and `footprint -p` on its pid; the attacker
   is a separate Python process.
4. n/a — nothing is zero.
5. n/a.
6. n/a.
7. DEFERRED for an owner decision. The cost is linear (about 1.2:1), not
   amplified, and the usual deployment puts a proxy in front; a fix adds a
   connection cap and a header deadline to public servers, which is a
   default the owner chooses.
8. KV-WS-01, -02 and -04 were set aside by reading current code (named in
   Target), not by a record. The http2 server binds a `ServerSocket` itself
   and was not measured (low priority).
9. L-23: on macOS RSS of idle memory falls under compression while it is
   still held; read `phys_footprint`. Price: one wrong reading of "released
   at 105 s" in this round.
A1. Separate processes and separate defaults.
A2. Volume.
L1. dart:io's single-block cap is the only refusal seen, and it is named as
    such; it does not bound the total.

## Gate

n/a — no code change.

## Not fixed

B-274, awaiting the owner. http2's server unmeasured.

## Links

Lens `../lenses/RPC-18-dependency-buffers-below-your-limits.md`.
Probe `../probes/P-277-held-request-header-blocks.md`.
Lead `../backlog/B-274-servers-hold-unfinished-request-headers-for-any-number-of-peers.md`.
Lesson `../lessons/L-23-rss-falls-while-the-memory-is-still-held.md`.
Lead `../backlog/B-27-a-tcp-syn-builds-an-endpoint.md`.
