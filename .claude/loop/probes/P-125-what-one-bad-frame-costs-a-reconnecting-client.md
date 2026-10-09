---
file: packages/transport/rpc_dart_websocket/.dart_tool/probe/b95_advisory_retires.dart
round: 486
commit: 931d8a0f
paths: [packages/core/rpc_dart/lib/src/resilience/client_connection.dart, packages/core/rpc_dart/lib/src/rpc/transports/channel_transport.dart, packages/transport/rpc_dart_websocket/lib/src/websocket_caller_transport.dart]
status: valid
---

# P-125 — what one bad frame costs a reconnecting client

## Why it exists

Two layers already decided that some errors are about ONE FRAME and not about
the connection — round 353's `IRpcAdvisoryChannelError`, and the lenient
`closeOnProtocolError: false` path that refuses a frame and keeps talking.
`RpcClientConnection` sits above both and had no such distinction.

The bench asks what a non-fatal observation costs a client that is behind the
reconnecting proxy, which is the configuration those decisions were made for.

## The harness

One long server-stream call running throughout, and a factory that COUNTS the
transports it builds — one per reconnect, and the only reconnect machinery in
the rig (the websocket transports are constructed bare, with no
`reconnectFactory` of their own).

Four arms, each with its own control:

1. **advisory** — a real websocket; the server writes one TEXT frame.
2. **lenient policy** — a channel pair; the peer sends 40 headers at a client
   that admits 16, `closeOnProtocolError: false`.
3. **real drop** — the peer socket closes with 1001. The capability, not the
   defect.
4. **strict policy** — arm 2's violation with `closeOnProtocolError: true`,
   where the SAME error type is genuinely fatal.

## The numbers (round 486)

```
                              built   the other call
advisory    text frame    before 1->2  errored, 3 msgs
advisory    text frame    after  1->1  alive,  87 msgs
advisory    nothing sent         1->1  alive,  88 msgs

lenient     bad metadata  before 1->2  errored, 3 msgs
lenient     bad metadata  after  1->1  alive,  89 msgs
lenient     nothing sent         1->1  alive,  89 msgs

real drop   (arm 3)              1->2  replacement serves a new call
strict      (arm 4)              1->2  errored -- correctly
```

## Measures

Transports BUILT by the factory: a direct count of connections the library
decided to replace, on the library's side of the boundary. Plus whether the
unrelated in-flight call errored, and how many messages it went on receiving.

## Control

Each arm's own "nothing sent" run, identical but for the one frame. Arms 3 and 4
are the inverse control: they show the bench still reads 2 when a reconnect is
the right answer, so `1` in arms 1 and 2 is a decision and not an inability to
count.

**Arm 4 is the sharp one.** It is the same `RpcFrameException.policy` as arm 2,
differing only in `closeOnProtocolError` — one error type, two outcomes. A fix
that keyed on the type alone passes arms 1-3 and fails here.

## What it establishes, and what it does not

Establishes: a frame-level observation cost a whole connection and every call on
it, and retiring on `onDone` instead keeps the fatal cases working.

Does NOT measure the flapping the lead describes — a proxy keepaliving every N
seconds — only the single event that causes it.

## Reading

(round 486), rpc_dart + rpc_dart_websocket — **counts the transports a factory
BUILDS**, one per reconnect, with the websocket transports constructed bare so
the proxy is the only reconnect machinery in the rig. Four arms, each with its
own control; the load-bearing one is the FOURTH, which sends arm 2's identical
`RpcFrameException.policy` with `closeOnProtocolError: true` and must still
read `1 -> 2`. A fix keyed on the error type passes the first three arms and
fails that one
