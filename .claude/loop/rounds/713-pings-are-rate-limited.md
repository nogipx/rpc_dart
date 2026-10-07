---
round: 713
verdict: FIXED
packages: [rpc_dart_websocket]
lens: RPC-18
bench: none — `.dart_tool/probe/audit_ws/ping_server.dart` + `ping_attacker.dart <port> 10 pongs`, two processes
commit: yes
release: changelog
---

# Round 713 — pings are rate-limited

## Target

B-263: a deaf client flooding pings grows the websocket server without bound.

## Hypothesis

dart:io answers every inbound ping with a pong on an unbounded write queue and
keeps parsing while the write side is blocked. Control frames never reach any
rpc_dart limit, so the pongs accumulate at the attacker's upload rate.

## Before

```
attacker sent 3433 MiB of pings in 10s (never reads)
t=18s server rssDelta=3145 MiB opened=1 closed=0
```

## Mechanism

As hypothesised. dart:io treats any pong as a keepalive reply, so unsolicited
pongs keep the 30 s keepalive from ever firing.

## Fix

`WebSocketFrameGuard`, which already parses every frame header on the bounded
upgrade path, rate-limits pings: a burst of 256, refilled at 16 a second; past
that the socket is destroyed. A keepalive pings once per interval; browsers do
not ping.

## After

```
t=8s server rssDelta=6 MiB opened=1 closed=1
```

## Canary

The library stashed: the socket witness times out with the connection still
open; the guard unit witness admits every ping.

## The verdict questions

1. Yes, same two processes. 2. Yes, defaults. 3. Yes, RSS of the server
process. 4. Not zero. 5. Quoted. 6. One cause. 7. A trade only for a peer
pinging over 16 a second sustained, which nothing legitimate does. 8. None.

## Gate

`analyze`, `format:check`, the rpc_dart_websocket suite (289 + 5).

## Not fixed

The compression-on path uses dart:io's transformer and is not guarded (B-266
item 6).

## Links

Lead `../backlog/B-263-a-ping-flood-grows-the-websocket-server.md` closed.
Lens `../lenses/RPC-18-dependency-buffers-below-your-limits.md` -- `applied: [..., 713]`.
