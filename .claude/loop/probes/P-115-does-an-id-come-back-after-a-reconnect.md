---
file: packages/transport/rpc_dart_websocket/.dart_tool/probe/does_an_id_come_back_after_a_reconnect.dart
round: 465
commit: d4c92857
paths: [packages/transport/rpc_dart_websocket/lib/src/websocket_caller_transport.dart, packages/transport/rpc_dart_http2/lib/src/transports/http2/rpc_http2_caller_transport.dart, packages/core/rpc_dart/lib/src/resilience/client_connection.dart]
status: valid
---

# P-115 — does an id come back after a reconnect?

## Why it exists

B-76's remaining half describes three mechanisms for stream-id reuse across a
reconnect and calls that a divergence. Rounds 449 and 451 both established that a
divergence is a lead about where to look and never a finding about what happens,
so the bench asks the only question that decides whether there is anything to
fix: **does an id come back?**

## The harness

All three caller-side machines in one run, against servers that accept and say
nothing — a WebSocket server, an HTTP/2 server that completes the handshake, and
for the proxy an `RpcClientConnection` over the second of those.

Per machine, two measures:

1. mint an id, **leave the call open**, reconnect, mint another — do they
   collide? The call must stay open, because an id is only reusable-and-harmful
   while something still holds it.
2. then `finishSending(oldId)`. That is the operation B-76's own body names as
   the cost of a collision — *"a dead call's late `finishSending(1)` ends the
   live one's request stream"* — and both it and `releaseStreamId` present
   nothing but the id, so nothing downstream can tell the calls apart.

The second measure is what makes the first mean something: two equal integers are
a curiosity, a teardown landing on a live call is a defect.

## The numbers (round 465)

```
             before  after  collision  late finishSending
websocket      1       3       no      no -- different id
http2          1       3       no      no -- different id
proxy          1       3       no      no -- different id
```

## Measures

The two ids, compared; and whether the late `finishSending` addressed the live
call or a dead one.

## Control

`_nextStreamId = 1` restored in http2's reconnect — the reset its own comment
says is deliberately absent:

```
http2          1       1      YES      YES -- same id
```

The bench sees the collision AND its consequence, so a clean row is a fact about
the code and not about the harness.

**And the control measured something the round was not looking for.** With
http2's counter reset, the PROXY arm — built on that same transport — still read
`1 / 3 / no`: its `_idWatermark` carries the sequence across a transport that
restarts its own. That is exactly what its doc comment claims and what nothing
had exercised.

## What it establishes, and what it does not

Establishes: none of the three machines hands back a live id across one
reconnect, and the proxy's watermark holds even when the transport under it
rewinds.

Does NOT cover several concurrent calls, repeated reconnects, or an id released
and re-minted within one connection. Unary shape only.

## Reading

all three caller-side reconnect machines in one run — mint an id, **leave the
call open**, reconnect, mint another, then `finishSending(oldId)`. The open
call is load-bearing: an id is only reusable-and-harmful while something still
holds it. The second measure is what makes the first mean something — two
equal integers are a curiosity, a teardown landing on a live call is the
defect the lead describes. Control: `_nextStreamId = 1` restored in http2's
reconnect, the reset its own comment says is deliberately absent, which reads
`1 / 1 / YES`. **That control also answered a question about another
machine**: with http2 rewound, the PROXY arm still read `no`, so its
`_idWatermark` carries the sequence across a transport that restarts its own
