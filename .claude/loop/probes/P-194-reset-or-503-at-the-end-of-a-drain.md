---
file: packages/transport/rpc_dart_http/.dart_tool/probe/b151_drain_then_force.dart
round: 573
commit: fb7770cd
paths: [packages/transport/rpc_dart_http/lib/src/rpc_http_server.dart, packages/transport/rpc_dart_http/lib/src/rpc_http_responder_transport.dart]
status: valid
---

# P-194 — reset or 503, at the end of a drain?

## Why it exists

Round 561 left B-151's item 2 with its requirement spelled out: a request in flight when the budget
runs out, and an observation of whether the peer gets a reset or the promised 503. Reading the method
does not place it — the force close IS the documented cut after the budget, so the claim is about
what the transport promises a request caught by it.

## The harness

A handler that takes 30 s against a 200 ms drain budget, so the request is certainly still pending
when the cut lands. **A raw `package:http` POST**, not the rpc_dart caller: what is being measured is
the HTTP outcome, and a caller in between would report its own interpretation of it.

`RpcHttpServer` exposes no bound port, so the arm picks a free one by binding and releasing a
`ServerSocket` — the same thing round 560's probe did.

Three arms: the drain budget expiring, `stop()` with no budget at all (the documented immediate cut,
and the second branch of the same method), and a CONTROL whose handler finishes inside the budget.

## The numbers (round 573)

Before:

```
WITNESS  drainTimeout 200ms, handler 30s
    ClientException: Connection closed before full header was received
ARM      no drainTimeout
    ClientException: ... the same
CONTROL  handler 100ms, budget 3s
    HTTP 200
```

After:

```
WITNESS  HTTP 503
ARM      HTTP 503
CONTROL  HTTP 200    unchanged
```

## Measures

What the client was told: an HTTP status line, an exception type, or nothing at all
(`NEVER ANSWERED` after a 10 s bound). Read once while the request is running and once after
`stop()`, so a reset is distinguishable from a request that never started.

## Control

**The handler that finishes inside the budget.** It reads `HTTP 200` before and after, which is what
says the rig completes requests and reads statuses — without it, two resets could be a harness that
never gets an answer at all.

**The ARM is a second site rather than a control**: `stop()` with no budget reaches the same step 4
after its own force close, so it read the same reset and needed the same fix.

## What it establishes, and what it does not

Establishes that a request still pending when the cut lands received a connection reset where the
transport's `close()` promises a 503, in BOTH branches of `stop()`, and that answering before the
force close — plus one event-loop turn for the write — delivers it.

**Establishes the turn specifically.** Reordering alone still read `ClientException`; the reading is
what showed that completing the completer only hands the response to shelf, and that there is nothing
to await for the write.

Does NOT cover a large pending body. One turn is enough for a 503, which `_reject` builds small;
anything that does not fit the socket buffer in one turn is not measured.

Does NOT read what the rpc_dart caller makes of the 503 — deliberately, since the probe's subject is
what reaches the wire.
