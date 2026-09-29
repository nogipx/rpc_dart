---
round: 518
verdict: DEFERRED
packages: [rpc_dart]
lens: RPC-08
bench: P-155 — new
commit: yes
---

# Round 518 — the fix that turned an error into a hang

## Target

The unary responder assuming one transport message holds one whole gRPC frame —
thirty-third in the audit's rank.

Lens RPC-08, shape 1: four call shapes implement one contract, and the battery run
against all of them at once is what makes "unary only" a measurement rather than a
reading.

## Hypothesis

A transport that delivers part of a gRPC frame per message breaks unary, while the
streaming shapes tolerate it.

## Before

```
CONTROL whole frames
   unary         got:64
   server stream got:64
   client stream got:64

each frame split in two
   unary         status 13: Failed to extract message from payload
   server stream got:64
   client stream got:64
```

Bench: `packages/core/rpc_dart/.dart_tool/probe/b126_fragmented_frames.dart`

**CONFIRMED exactly as filed.** The two streaming shapes share the transport, the
channel, the codec and the payload with unary in the same run — only the responder
differs — so this is a statement about the unary path, not about the rig.

## Mechanism

Three layers, and the lead names two of them.

1. `UnaryResponder.handleMessage` sets `requestHandled = true` before parsing, then
   parses ONE chunk and throws INTERNAL if it yields nothing complete.
2. `_ensureUnaryResponder` hands the responder `preBindMessages.first` — the rest of
   the buffered messages are dropped.
3. **Not in the lead:** `await _cleanupStream(streamId)` runs immediately after, so
   the stream state is gone before any later fragment could arrive.

## After

Nothing. **`lib/` is unchanged, and that is this round's result.**

## Canary

n/a — nothing was fixed.

## Why the fix was attempted and reverted

The sketch says "accumulate until a message is complete". That was implemented:
parse before marking `requestHandled`, return and wait when the parse yields nothing,
and error only if the peer half-closed mid-frame. The parser is per-call state, so
feeding it partial chunks is exactly what it is built for.

It did not work, and it made things WORSE:

```
each frame split in two
   unary   status 4: Deadline exceeded (timeout: 0:00:02.999)
```

**An immediate INTERNAL became a hang until the deadline.** The second fragment has
no route: layer 2 dropped it, and fixing layer 2 as well still left layer 3, where
the stream is cleaned up before the fragment arrives.

A hang is worse than a clear error, so both edits were reverted and `lib/` is
byte-identical to its committed state — verified with `git diff --stat`, which shows
nothing.

**A partial fix here is not a smaller improvement, it is a regression.** The three
layers have to move together or not at all.

## Gate

Not run: nothing in `lib/` or `test/` changed.

## Not fixed

Making unary tolerate fragmentation means changing the unary call LIFECYCLE, not one
parse:

- feed every buffered pre-bind message, not just the first;
- keep the stream alive until the request is complete or the peer half-closes,
  rather than cleaning up straight after the first feed;
- route post-bind data frames to a unary responder that has `listensToTransport:
  false` and is fed by the pipeline.

That is a real change to a hot, well-tested path, for a case no shipped transport
produces.

**The other half of the sketch is the cheap one and is still available: document the
invariant on `IRpcTransport`.** Round 507 has already established the precedent —
`IRpcChannel.incoming` now states that a delivered chunk is handed over, not lent,
because the framing layer relies on it. "A transport message carries whole gRPC
frames" is the same kind of contract, currently relied upon by one shape and stated
nowhere.

That is the owner's call: document the invariant, or pay for the lifecycle change.

## Links

Lens RPC-08. Bench P-155 (new). Lead B-126 (awaiting owner). Round 507 is the
precedent for stating a transport invariant rather than defending against its
violation.
