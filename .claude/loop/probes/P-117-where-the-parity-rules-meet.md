---
file: packages/transport/rpc_dart_http2/.dart_tool/probe/where_the_parity_rules_meet.dart
round: 468
commit: 9e9fcd67
paths: [packages/transport/rpc_dart_http2/lib/src/transports/http2/rpc_http2_caller_transport.dart, packages/core/rpc_dart/lib/src/resilience/client_connection.dart, packages/core/rpc_dart/lib/src/core/transport.dart]
status: valid
---

# P-117 — where the parity rules meet

## Why it exists

B-89 names three homes for the stream-id parity rule and says outright that
nothing has been shown to bite — then names the ONE path where two of them meet:
`RpcClientConnection` carries an `_idWatermark` out of `lastIssuedStreamId` and
into `resumeStreamIdsAfter` across a transport swap. *"Establish it rather than
assuming"* is the lead's own instruction.

## The harness — two arms, deliberately at different levels

**Direct**: the http2 caller's `resumeStreamIdsAfter` driven at its own boundary
with every parity, including values far from the current counter. This is the
rule under test with nothing in front of it.

**Through the proxy**: `RpcClientConnection` over http2, three swaps, three ids
minted between each — an ODD count on purpose, so a naive carry lands on an even
one. This is the rule as it is actually reached.

Both are needed and neither substitutes: the first says whether the rule is
right, the second says whether it is ever asked.

## The numbers (round 468)

```
resumeStreamIdsAfter, driven directly
  watermark=  1 (odd )  -> 3, 5     both ODD
  watermark=  2 (even)  -> 5, 7     both ODD
  watermark=  8 (even)  -> 11, 13   both ODD
  watermark=100 (even)  -> 103, 105 both ODD

through RpcClientConnection, across three swaps
  ids = [1, 3, 5, 7, 9, 11, 13, 15, 17, 19]
  even ids = NONE   strictly increasing = true
```

## Measures

The parity of every id minted, and whether the sequence ever rewinds. Both are
read off `createStream()` — the transport's own answer, not the bench's.

## Control

`final aligned = streamId;` in place of the round-up, which is the alignment
deleted:

```
watermark=  2 (even)  -> 4, 6     PARITY BROKEN
watermark=  8 (even)  -> 10, 12   PARITY BROKEN
watermark=100 (even)  -> 102, 104 PARITY BROKEN
```

**And the proxy arm stayed CLEAN under the same ablation.** That is the sharper
result: the alignment is not merely correct on that path, it is never exercised
on it — `lastIssuedStreamId` is `_nextStreamId - 2`, odd by construction. An
ablation that cannot reach an arm has said something about the arm.

## What it establishes, and what it does not

Establishes: the http2 caller's rule is correct at every input and never rewinds;
nothing inside this library ever hands it an even watermark; and the alignment is
reachable only from the public transport surface.

Does NOT cover the websocket transport, which uses `RpcStreamIdManager` and is
the rule's first home rather than a fourth. Nor the http2 responder, which has no
entry point at all — established by reading its `implements` clause, not here.
