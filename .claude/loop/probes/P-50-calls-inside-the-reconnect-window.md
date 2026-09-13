---
file: packages/transport/rpc_dart_websocket/.dart_tool/probe/calls_inside_the_reconnect_window.dart
round: 359
commit: 164bb41b
paths: [packages/transport/rpc_dart_websocket/lib/**]
status: valid
---

# P-50 — what each transport method does mid-reconnect

Drives all six `IRpcTransport` methods against one caller transport in each of
the three states it can be in, and prints a method-by-state table. Add a method
by adding a case to `_probeMethod`; add a state by adding an arm.

The stream id is minted while HEALTHY, so `_idsOnThisConnection` holds it and
the per-id guards can never be what refuses a call — without that, every arm
returns early for the wrong reason.

## Measures

One outcome word per cell, on the library's side: the id returned, `returned`,
the exception type, or `HUNG`.

## Control

Two of the three arms ARE the controls, and that is the point of the shape:
`healthy` and `disconnected` are the states the code means to have, and
`in-window` is the one nobody named. A correct transport makes the in-window
column equal the disconnected column.

```
method                 healthy     in-window (before)      disconnected
createStream           id=3        id=3                    StateError
sendMetadata           returned    returned                StateError
sendMessage            returned    returned                StateError
sendDirectObject       Unsupported Unsupported             Unsupported
finishSending          returned    returned                returned
getMessagesForStream   HUNG        RpcStatusException(14)  StateError

                       healthy     in-window (after)       disconnected
createStream           id=3        StateError              StateError
sendMetadata           returned    StateError              StateError
sendMessage            returned    StateError              StateError
sendDirectObject       Unsupported StateError              StateError
finishSending          returned    returned                returned
getMessagesForStream   HUNG        StateError              StateError
```

`finishSending` returning in every arm is correct and load-bearing: it runs from
`finally` blocks, where a throw masks the error that got there. A fix that made
that column throw would be a worse defect than the one being fixed.

`sendDirectObject` reading `Unsupported` in all three arms BEFORE is the bench
reporting honestly that it cannot see that half: the frame channel refuses
zero-copy whatever the state, so the missing guard had no observable effect
until the guard existed to change the answer.
