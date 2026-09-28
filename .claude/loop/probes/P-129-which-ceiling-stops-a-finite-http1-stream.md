---
file: packages/transport/rpc_dart_http/.dart_tool/probe/b99_stream_caps.dart
round: 490
commit: a12a4209
paths: [packages/transport/rpc_dart_http/lib/src/rpc_http_caller_transport.dart, packages/transport/rpc_dart_http/lib/src/rpc_http_responder_transport.dart, packages/core/rpc_dart/lib/src/core/parser.dart]
status: valid
---

# P-129 — which ceiling stops a finite HTTP/1.1 stream

## Why it exists

The caller's class doc promises that a FINITE server stream succeeds, fully
buffered. Two limits may contradict it, and they are different KINDS of limit —
one counts bytes, one counts messages — so a bench that varies only size would
find one and report the other as absent.

## The harness

The same contract run over HTTP/1.1 and over a channel pair, which is the
control: the channel transport meets neither ceiling the same way, so a row that
differs between them is the transport's doing rather than the contract's.

Three shapes, chosen so each trips exactly one ceiling:

- `1500 x 10 B` — 22 KB total, far inside any byte budget, past the 1024
  message count.
- `20 x 1 MiB` — 20 items, far inside the count, past the 16 MiB byte budget.
- `100 x 10 B` — inside both. The control that says the rig works at all.

Then each ceiling raised ALONE, and both together, which is what shows they are
two and not one.

## The numbers (round 490)

```
                       http                      channel
1500 x 10 B      FAILED after 0 status=8       OK 1500
20 x 1 MiB       FAILED after 0 status=8       OK 20
100 x 10 B       OK 100                        OK 100

client-stream upload
1500 x 10 B      status=8
4 x 1 MiB        got:4

each knob raised alone, http           before      after
+maxBufferedBytes      20 x 1 MiB      FAILED      OK 20
+maxMessagesPerChunk   1500 x 10 B     OK 1500     OK 1500
+both                  either shape    -           OK
```

## Measures

Items DELIVERED to the caller, and the status when it fails. Counting delivery
rather than bytes is what makes the two ceilings distinguishable: both answer
RESOURCE_EXHAUSTED, and only the shape that provoked it says which fired.

## Control

The channel-pair column, same contract and same counts. And `100 x 10 B`, which
passes everywhere.

`+maxBufferedBytes` reading FAILED before and OK after is the ablation: the knob
named for this bounded nothing, because all three body sites used the
per-MESSAGE limit instead.

## What it establishes, and what it does not

Establishes: a finite stream past either ceiling fails rather than degrades, the
class doc was wrong, and the byte ceiling was not raisable by the knob that
names it.

Does NOT test the ping-pong bidi the lead also describes (send, await a reply,
send again), which would hang rather than fail. Nothing here would see a hang.
