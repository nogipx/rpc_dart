---
status: awaiting owner
round: 518
commit: 9c69500d
paths: [packages/core/rpc_dart/lib/src/rpc/streams/unary/responder.dart, packages/core/rpc_dart/lib/src/endpoint/responder_pipeline.dart, packages/core/rpc_dart/lib/src/core/transport.dart]
probe: P-155
reason: "CONFIRMED — unary alone fails on a fragmented frame while both streaming shapes answer. The sketch's accumulate half was implemented and REVERTED: it turns an immediate INTERNAL into a hang, because two further layers drop the later fragment. The choice is documenting the invariant on IRpcTransport (cheap, precedent in round 507) or paying for a unary lifecycle change"
---

# B-126 — the unary responder assumes one transport message holds one whole gRPC frame

**Filed from the external audit of 2026-09-28** (core + transports, read in full,
transport findings re-checked against the code). Confidence from reading:
**high**. Nothing here was measured; the witness below is the first
thing a round owes this lead, and it may refute it.

`handleMessage` sets `requestHandled = true` and parses ONE chunk; an empty parse is INTERNAL "Failed to extract message from payload"; the pipeline hands it only the first pre-bind message — the streaming shapes tolerate fragmentation, unary does not, and nothing states the invariant.

## The shape

`packages/core/rpc_dart/lib/src/rpc/streams/unary/responder.dart` `handleMessage` (`_parserFor(state)(payload)`,
`if (messages.isEmpty) throw`), `responder_pipeline.dart:1418-1428`.

## Why it matters

Every shipped transport delivers whole frames, so nothing fails today; a
third-party transport that forwards raw chunks breaks unary only.

## Witness a round would build

A test transport that splits each frame in two: unary vs server-stream outcome.

## Fix sketch

Accumulate until a message is complete, or document the invariant on
`IRpcTransport`.

## Outcome (round 518) — CONFIRMED, and the sketch's fix was reverted

```
CONTROL whole frames        unary got:64   server stream got:64   client stream got:64
each frame split in two     unary status 13   server stream got:64   client stream got:64
```

The streaming shapes share the transport, channel, codec and payload with unary in
the same run — only the responder differs.

**Three layers, and this lead names two:**

1. `handleMessage` sets `requestHandled = true` BEFORE parsing, parses one chunk and
   throws INTERNAL if nothing completes.
2. `_ensureUnaryResponder` hands over `preBindMessages.first` and drops the rest.
3. **Not in the lead:** `_cleanupStream(streamId)` runs immediately after, so the
   stream is gone before a later fragment could arrive.

**"Accumulate until a message is complete" was implemented and reverted.** With
layer 1 fixed, unary stopped returning INTERNAL and started hanging to its deadline —
`status 4: Deadline exceeded` — because the second fragment has no route. **A partial
fix here is a regression, not a smaller improvement:** a hang is worse than a clear
error. `lib/` is byte-identical to its committed state.

## Owner decision

Two ways, and they are not close in cost.

1. **Document the invariant on `IRpcTransport`** — "a transport message carries whole
   gRPC frames". Cheap, and there is precedent: round 507 added exactly this kind of
   contract to `IRpcChannel.incoming` when the framing layer started relying on it.
   The invariant is relied upon TODAY by one shape and stated nowhere.
2. **Pay for the unary lifecycle change** — feed every buffered pre-bind message,
   keep the stream alive until the request completes or the peer half-closes, and
   route post-bind data frames to a responder that has `listensToTransport: false`.
   A real change to a hot, well-tested path, for a case no shipped transport produces.

The lead's own note argues for (1): *"Every shipped transport delivers whole frames,
so nothing fails today."* What (2) buys is tolerance of a third-party transport that
does not — which is a capability decision rather than a defect repair.
