---
status: closed (round 529)
round: 529
commit: f086c61c
paths: [packages/transport/rpc_dart_websocket/lib/src/websocket_caller_transport.dart]
probe: none — a witness and three controls, no numbers to compare
reason: "CONFIRMED and FIXED. The constructor now defaults to `nobody is pinging this socket`, which is all it can know, and `connect()` passes `platformHonoursPingInterval` — the one call site where that constant's premise holds. The lead's fix sketch was not implementable: the channel packages keep the socket private"
---

# B-133 — websocket `pingInterval` does nothing when the transport is constructed directly on the VM

**Filed from the external audit of 2026-09-28** (core + transports, read in full,
transport findings re-checked against the code). Confidence from reading:
**medium**. Nothing here was measured; the witness below is the first
thing a round owes this lead, and it may refute it.

On the VM `platformHonoursPingInterval` is true, so the app-level heartbeat is off, but only `connect()` puts the interval on the dart:io socket — a caller who builds the channel and passes `pingInterval:` gets no keepalive; `platformHandlesPing` is a test hook on the public API.

## The shape

`packages/transport/rpc_dart_websocket/lib/src/websocket_caller_transport.dart:142-144`.

## Why it matters

A documented keepalive silently absent for one construction path.

## What round 529 measured

```
  hand-built channel, pingInterval: 200ms       never noticed (capped at 5s)
```

CONFIRMED: both keepalives off. After the fix that arm notices, while three controls hold —
the same construction with no interval notices nothing, an explicit
`platformHandlesPing: true` still switches ours off, and `connect()` gains no second probe.

**A trap the round hit and recorded**: a dart:io `WebSocket` answers a ping frame ITSELF,
before any listener sees it, so a server that answers no RPC is still a live path for a
native keepalive. A control asserting native detection against such a server fails for a
reason unrelated to the fix.

## Fix

**The sketch was not implementable.** "Apply the interval to the passed socket when it is a
dart:io `WebSocket`" needs the socket, and `IOWebSocketChannel` / `AdapterWebSocketChannel`
expose no accessor for it — so the constructor can neither set a native ping nor ask whether
one is running.

What was done instead: the constructor defaults to "nobody is pinging this socket", which is
all it can know, and `connect()` passes `platformHonoursPingInterval` explicitly — the one
call site where that constant's premise holds, since it describes `openWebSocket`.
`platformHandlesPing` stops being a test hook and becomes how a caller who built the socket
with a native ping says so.

**Behaviour change on a published package**: a direct construction with `pingInterval` now
runs an RPC-level probe on the VM where it previously ran nothing. Wants a CHANGELOG line.

## Owner decision

—
