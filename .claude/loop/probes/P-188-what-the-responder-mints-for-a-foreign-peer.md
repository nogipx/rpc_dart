---
file: packages/core/rpc_dart/.dart_tool/probe/b220_responder_mints.dart
round: 566
commit: 4541c0c1
paths: [packages/core/rpc_dart/lib/src/endpoint/responder_pipeline.dart, packages/core/rpc_dart/lib/src/contracts/context.dart]
status: valid
---

# P-188 — what does the responder mint for a peer that sends no correlation headers?

## Why it exists

`P-179` established one token per call and that the responder mints nothing — against ONE
peer, an rpc_dart caller through `RpcCallerEndpoint`, which always sends both `x-request-id`
and `x-trace-id`. Both headers are this library's own rather than gRPC's, so the interesting
peer is the one that sends neither, and that arm did not exist.

## The harness

**The same instrument as P-179, which needs no instrumentation**: a token's last 4 bytes are a
process-wide monotonic counter, so a token is its own receipt — the count comes from a counter
delta and the IDENTITY from decoding each id.

The foreign peer needs no fake server. `RpcMetadata.forClientRequest` carries content-type and
grpc-accept-encoding and nothing else, so driving `RpcChannelTransport.pair()`'s client side
directly — `createStream`, `sendMetadata`, `sendMessage(endStream: true)` — IS the foreign
shape, through public API.

Three arms, each a fresh pair and responder, with one warm call discarded:

- **the case** — neither header;
- **CONTROL A** — both headers, what rpc_dart sends;
- **CONTROL B** — a foreign `x-request-id` and no trace id, the arm a fix must not change.

**Its mint decoder cuts at the FIRST underscore**, not the last. P-179's copy uses
`split('_').last` and base64url's alphabet contains `_`, so that version reads `null` for
roughly half of all tokens.

## The numbers (round 566)

Before:

```
  neither header        tokens minted 2
      requestId=req_ZbE6pxfSlttsABpVAAAABA (mint 4)
      traceId=trace_UpSsG7zi7untof4sAAAABQ (mint 5)
  both headers          tokens minted 0
  foreign request id    tokens minted 1
```

After:

```
  neither header        tokens minted 1
      requestId=req_axmmTRiORcAUjGuOAAAAAw (mint 3)
      traceId=trace_axmmTRiORcAUjGuOAAAAAw (mint 3)
  both headers          tokens minted 0   unchanged
  foreign request id    tokens minted 1   unchanged
```

## Measures

Tokens minted per call, by counter delta, and which token each id carries, by decoding its
mint number. A count alone cannot tell one token used twice from two tokens; the mint numbers
can, which is why both are read.

## Control

**Two, and they answer different objections.** CONTROL A is the shape P-179 measured and reads
0 before and after, so the change is confined to the peer that sends nothing. CONTROL B is the
arm that MUST still mint — `traceIdFor` can only derive from an id of ours — and its unchanged
1 is what stops the fix from being "stop minting", which would have handed a foreign peer a
trace id derived from a string this library never issued.

Before the fix the case read 2 against CONTROL A's 0, so the bench separates the two peers.

## What it establishes, and what it does not

Establishes that the responder minted a second token for any peer that is not rpc_dart, that
the id was derivable from the one it had just minted, and that deriving it leaves both controls
where they were.

Does NOT price the saving as a share of a call on a real transport. One token is `~42 us` by
P-179 on a byte pipe; over http2 or websocket the wire dominates, and this probe times nothing
— it counts.

Does NOT cover the streaming shapes. A client-stream or bidi call from a foreign peer reaches
the same `_contextFromHeaders`, by reading, but no arm here varies the shape.
