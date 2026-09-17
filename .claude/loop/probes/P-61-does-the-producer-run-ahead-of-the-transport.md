---
file: packages/core/rpc_dart/.dart_tool/probe/request_sink_backpressure.dart
round: 370
commit: 9428d654
paths: [packages/core/rpc_dart/lib/src/rpc/streams/bidirectional/caller.dart, packages/core/rpc_dart/lib/src/rpc/streams/client/caller.dart, packages/core/rpc_dart/lib/src/rpc/transports/channel_transport.dart]
status: valid
---

# P-61 — does the producer run ahead of the transport?

## Why it exists

B-49 named the shape by reading — one sibling pauses its request subscription
and the other does not — and deliberately refused to borrow the sibling's own
32.8 MB figure, because that number was taken on a different API. This is the
number for the API in question.

## Measures

How many messages the LIBRARY pulled out of the application's producer while the
handler was stalled, counted inside the producer's own generator. That is the
application's side of the boundary, so it measures demand the library created
and nothing the probe arranged. Reported as a count and as MB.

Rig: a handler that takes one message and stalls, a **1 MB** flow-control
window, **16 KiB** messages, 2000 offered, sampled at 900 ms.

## Control

The sibling, on the same rig in the same run: `ClientStreamCaller.call(Stream)`,
which pauses its request subscription for the duration of each send. It differs
from the case under test by exactly that pause.

It stops at **66 messages — 1.0 MB — which is the window**, so the bench is not
merely reporting "fewer" but landing on the value the mechanism predicts. A bench
whose control drifted with the timing could not make that claim.

## The numbers (round 370)

```
                 pulled of 2000      MB     while the handler was stalled
requestSink        2000            31.3     <- before
requestSink          68             1.1     <- after
call(Stream)         66             1.0     <- control, unchanged
```

2000 is the probe's ceiling, not a plateau: the producer was exhausted. A real
producer — the file upload the owner described — has no such ceiling.

## What it establishes, and what it does not

Establishes: the caller creates unbounded demand on its producer, and the fix
lands it on the sibling's value.

Does not establish anything about a direct `sink.add()`, which a `StreamSink`
accepts unconditionally by contract. The bound reaches producers driven through
`addStream`, which is what an upload uses.

Taken on `RpcChannelTransport.pair()`. That is adequate here and was checked:
the control lands on the window rather than on zero, so the in-process pair does
apply the window (unlike P-58's park question, which it flattens).
