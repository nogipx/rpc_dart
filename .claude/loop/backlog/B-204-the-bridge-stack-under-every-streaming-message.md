---
status: open
round: 509 (measured as part of B-118; split out in the round-540 bookkeeping pass)
commit: 6659c0ee
paths: [packages/core/rpc_dart/lib/src/endpoint/responder_pipeline.dart, packages/core/rpc_dart/lib/src/endpoint/caller_pipeline.dart, packages/core/rpc_dart/lib/src/rpc/streams/base_processor.dart]
probe: P-147
reason: "cost — the middleware wrappers are gone when there is no middleware; ~4.4 us per message remains in the bridge stack below them, and not one of those layers was varied"
---

# B-204 — the bridge stack under every streaming message, none of it varied

Split out of B-118, which round 509 closed after making the middleware helpers return the
source stream unchanged when no middleware is registered. Bench
`../probes/P-147-what-does-a-streaming-message-pay.md`.

**What remains, and where.** Roughly 4.4 us per message in layers the parent lead also
named and round 509 did not touch: `handleServerStream`, `_withHandlerSlotStream`,
`StreamBridge`, `_bridgeCallerResponses`, the bidi controller and its `.transform`, and the
`StreamProcessor` / `CallProcessor` controllers that only a no-op listener reads.

**It is not only a cost question.** The parent lead ties these bridges to the dart2js
`async*` cancel problems they were added to work around, so collapsing the stack owes the
WEB target a measurement — `melos run test:web`, and RPC-07's reading that the web is a
separate runtime rather than a variant.

B-118 was closed rather than left open because what remains is a different change with no
measurement behind it. This is that filing.

## Why it matters

Per-message cost on every streaming call, in a stack whose layers each have a reason nobody
has re-checked.

## Witness a round would build

P-147's per-message timing with ONE layer ablated at a time — the only way to attribute
4.4 us across six of them — and every arm re-run on dart2js, because that is what the
bridges are for.

## Owner decision

—
