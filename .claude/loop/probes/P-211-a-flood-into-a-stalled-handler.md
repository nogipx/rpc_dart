---
file: packages/core/rpc_dart/.dart_tool/probe/b138_a_flood_into_a_stalled_handler.dart
round: 594
commit: 017f4c88
paths: [packages/core/rpc_dart/lib/src/endpoint/responder_pipeline.dart, packages/core/rpc_dart/lib/src/endpoint/responder_streams.dart, packages/core/rpc_dart/lib/src/rpc/transports/channel_transport.dart]
status: valid (round 595)
---

# P-211 — a flood into a stalled handler

## Why it exists

B-138: what bounds an upload from a peer that ignores flow control, once the
stream is really dispatched to a handler. P-210 had no responder attached; this is
its repair.

## The harness

A real `RpcResponderEndpoint` on the default policy and an `RpcCallerEndpoint`
whose transport has its windows off — separate policy objects, so the peer's
policy cannot bound the victim. Requests come from an `async*` generator, so
PULLED is the library's demand. The handler reads one message and parks.

RETAINED is the reading: at the plateau the producer is stopped and the handler
released, and what it then drains is exactly what the responder side held. RSS
was tried first and is too noisy across runs at one scale (`+202` and `-145` MiB
for the same arm).

One arm per process: `control`, `witness [N]`, `bidi`.

## The numbers (round 594)

```
                                            PULLED    RETAINED
CONTROL  client-stream, peer honours window    258      257  (~4 MiB)
WITNESS  client-stream, before the fix       20000    19999  (~312 MiB)
WITNESS  client-stream, after the fix        20000     1023  (~16 MiB)
SIBLING  bidi, peer ignores window           20000     1023  (~16 MiB)
```

## Round 595 — N streams on one connection

Arms `multi N`, `multihonest N`, `multibidi N`, 2000 messages per stream:

```
                                   streams   before    after
client-stream, peer ignores window    8       8184     4093
client-stream, peer ignores window   16      16368     4093
bidi, peer ignores window            16          -     4093
client-stream, honest peer            8       2056     2056
```

## Round 609 — both layers on one connection

Witnessed in `test/transports/the_connection_total_is_bounded_test.dart`, arm
`mixed`: 8 streams, even ones bidi, odd ones client-stream, a 128 KiB connection
window and 1 KiB messages (ceiling 128):

```
                                     retained
before (one total per layer)            252
after  (one shared total)               126
```

## Measures

Messages the responder side held for a parked client-stream handler.

## Control

The same call with the peer honouring the window: 257 against 19999.
