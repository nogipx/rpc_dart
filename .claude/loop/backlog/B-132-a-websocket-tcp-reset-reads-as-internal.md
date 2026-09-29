---
status: closed (round 528)
round: 528
commit: f53f3c46
paths: [packages/transport/rpc_dart_websocket/lib/src/rpc_websocket_channel.dart]
probe: P-162
reason: "CONFIRMED in both halves and FIXED. dart:io sets 1002 on any socket error, so a TCP reset was non-retryable INTERNAL naming a peer that said nothing; and a raw channel error reached the caller as the channel package's own exception type"
---

# B-132 — websocket: a local connection reset surfaces as INTERNAL "closed by peer 1002"

**Filed from the external audit of 2026-09-28** (core + transports, read in full,
transport findings re-checked against the code). Confidence from reading:
**low-medium**. Nothing here was measured; the witness below is the first
thing a round owes this lead, and it may refute it.

Dart:io sets close code 1002 itself on a socket error (to verify on the SDK); 1002 is not in `saidNothing`, so the channel emits a non-retryable INTERNAL naming the peer; raw channel errors (`WebSocketChannelException` on web) are forwarded with no gRPC status at all.

## The shape

`packages/transport/rpc_dart_websocket/lib/src/rpc_websocket_channel.dart:31-36` (table), `:131-133` (raw `onError`),
`:149-164` (`onDone` mapping).

## Why it matters

The commonest network failure, a TCP reset, becomes INTERNAL (final) instead of
UNAVAILABLE (retryable).

## What round 528 measured

```
  how                            closeCode   the call got
  TCP RESET mid-call             1002        status 13 — WebSocket closed by peer with code 1002
  CONTROL peer vanishes (FIN)    1005        status 14 — The stream closed before the peer sent a status
  CONTROL peer closes 1001       1001        status 14 — The stream closed before the peer sent a status
  CONTROL peer closes 1011       1011        status 13 — WebSocket closed by peer with code 1011: server fault
  raw channel error (the web path)           raw WebSocketChannelException
```

Bench `../probes/P-162-what-status-does-each-ending-give.md`. The reset is produced, not
simulated: Dart has no SO_LINGER, so the rig relays bytes, stops draining the client, then
destroys the socket — closing with unread bytes in the receive queue is what sends RST.

**Mechanism read from the SDK.** `websocket_impl.dart`'s socket `onError` calls
`_close(WebSocketStatus.protocolError)`, assigns it to `_closeCode` and closes the controller
WITHOUT an error, so a socket failure is indistinguishable from a protocol close. And this
library never sends 1002 itself (its own framing-violation code is 4400), so between two
rpc_dart peers the local path is the only source.

## Fix

1002 moved to `unavailable` with the platform reason recorded next to it, and the message no
longer names the peer for that one code — every other code reaching that point was sent by
the peer. `onError` wraps a non-`RpcException` in `RpcStatusException(unavailable, ...)`;
`RpcException`s pass through so the advisory non-binary-frame report is not turned into a
dead connection.

**Loosens one thing**: a peer that genuinely sends 1002 is now retried, bounded by the retry
policy. Behaviour change on a published package — wants a CHANGELOG line at release.

## Owner decision

—
