---
status: decided by owner (round 540)
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

## DECIDED in the round-540 review: option 2, the unary lifecycle change

Against this record's own recommendation, and deliberately: tolerating a transport that
fragments is a capability the library should have, and unary being the ONE shape that
cannot take it is the wrong asymmetry to write down as intended.

**What the round must not repeat.** Round 518 implemented the sketch's accumulate half and
REVERTED it, because two further layers drop the later fragment — so accumulating in the
unary responder ALONE turns an immediate INTERNAL into a HANG. That is measured, not feared.
All three parts of option 2 are load-bearing:

- feed every buffered pre-bind message, not just the first;
- keep the request stream alive until the request completes or the peer half-closes;
- route post-bind data frames to a responder with `listensToTransport: false`.

**A hang is worse than the error being fixed**, so the witness needs both arms: a fragmented
frame ANSWERED, and a peer that stops mid-frame answered with a status rather than left
waiting. The second arm is the canary for the failure this fix can introduce.

**Take the reachability reading first if it is cheap** — which shipped transport can be made
to fragment at all. It does not change the decision, but it sizes the risk of touching a hot
path and tells the round whether an end-to-end witness is constructible without a
hand-written transport.

## Attempt 2 (round 547) — built, both arms passing, REVERTED

`../rounds/547-the-second-revert.md`. `lib/` is byte-identical to its committed state. **The
decision is not reversed**; what follows is the constraint any third attempt must satisfy.

**The reachability reading, as asked.** No shipped transport fragments: http2's responder keeps a
per-stream `RpcMessageParser` with `emitFramed: true`, the frame channel reassembles, HTTP/1.1
buffers the whole body. The witness must be built, and this is a capability change.

**Five parts, not three** — the decision's three plus two it did not name: keep the per-stream
state (it owns the parser) while a frame is incomplete, and answer INVALID_ARGUMENT when the peer
half-closes mid-frame. Both witnesses passed:

```
each frame split in two   unary got:64
peer stops mid-frame      unary status 3: ... the last gRPC frame is incomplete
```

### THE BLOCKER, and it is not a detail

**`RpcMessageParser` returning no messages does not mean "incomplete".** It also means
"refused". A 32 MB payload compressed against a **1 MB configured policy**:

```
expected  contains 'max: 1048576'      (RESOURCE_EXHAUSTED, the operator's limit)
actual    status 3 'Request stream closed mid-message ... the last gRPC frame is incomplete'
```

A security control reporting the wrong status and no longer naming the limit it enforces —
worse than the INTERNAL this lead is about. The whole design rested on a distinction the parser
does not expose.

**A third attempt must take that distinction FROM the parser**, which knows whether it holds a
partial frame, and not from the emptiness of its result. Adding that is the first step, not the
fix.

### What the canaries established, so it is not re-derived

- the half-close answer is what prevents the HANG (round 518's regression reproduced exactly by
  ablating it: `status 4: Deadline exceeded`);
- the fragment ROUTING is what makes the call succeed rather than fail cleanly;
- **"feed every buffered message" is unwitnessed** — a bench arm was built for it (fragments
  reordered ahead of their metadata) and ablating it changed nothing, because the routing reaches
  every case. Keep it or drop it on judgement, not on evidence.

### Ready to reuse

`test/streams/unary_tolerates_a_fragmented_frame_test.dart` is in the tree with both witnesses
SKIPPED and the condition in the skip reason; its two guards run. `P-155` gained the `truncate`
and `reorderMetadata` arms.

**And one trap worth knowing before touching this again**: `requestHandled` read the per-stream
state, which `handleMessage`'s `finally` removes — so a COMPLETED call reported "still arriving"
and the pipeline skipped the teardown it owed. That surfaced as an undisposed call scope and an
unreleased http2 endpoint, two failures away from the code that caused them.
