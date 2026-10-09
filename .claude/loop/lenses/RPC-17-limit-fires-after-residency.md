---
refines: —
paths: [packages/core/rpc_dart/lib/src/core/**, packages/core/rpc_dart/lib/src/rpc/transports/**, packages/transport/rpc_dart_http/lib/**, packages/transport/rpc_dart_websocket/lib/**, packages/core/rpc_dart_compression/lib/**]
applies: a size limit exists on one direction, and something buffers in the other before any limit is consulted
breaks: DoS.
applied: [236, 279, 280, 350, 489, 506, 507, 509, 511, 512, 513, 519, 534, 549, 550, 564, 565, 568, 570, 578, 593, 594, 595, 598, 636, 645, 660, 709, 710, 711, 714, 715, 719, 720, 724]
status: confirmed (round 720)
rank: 9
---

# RPC-17 — A limit that fires after the bytes are resident

## Shape

Distinct from "no limit at all", and it reads as safe in review: the limit
**exists**, and it sits one layer too late, so the allocation it was meant to
prevent has already happened when it fires. The reviewer's question "is there a
length check?" is the wrong question. **The question is what runs BEFORE it.**

## Detector

Every inbound buffering site, read as an ORDER OF STATEMENTS rather than for the
presence of a guard: `RpcFrameMultiplexedChannel._onData`, the caller and
responder body readers in rpc_dart_http, every decompressor
(`RpcGrpcCompression.decompress`, `compression_gzip_io.dart`, the
`RpcGzipCodec` in rpc_dart_compression), and `bufferPreMethod` in core.
For each: is the chunk appended to a buffer before the cap is consulted? A cheap
syntactic query: for every limit check, what is the nearest `return null` /
`continue` / `await` ABOVE it, and can untrusted input reach that first?

Then the second, harder half — **which DIMENSION does each nearby limit
measure?** `maxActiveStreams` counts streams (one is enough),
`maxMessageLengthBytes` bounds ONE frame (each can be legal),
`halfOpenStreamTimeout` bounds time, not volume. The class lives in the gap
between the dimensions, where nothing measures TOTAL BYTES. A per-stream bound
is a per-connection bound times N.

Third: a peer-controlled amplification factor. Where the buffer is inside a
dependency that cannot be patched, the only lever is whether to negotiate the
FEATURE at all, and an untrusted-facing default must fail closed.

Also: read the direction the lens does NOT name (outbound); list every PATH into
a protected buffer, per call shape, and mark which pass through the limit's
layer; ask which queues a weigher is not applied to; and check whether the limit
is on the path the bytes arrive by at all.

**The asymmetry to look for:** a server bounds what CLIENTS send it and forgets
that it is also a client of its peers. `RpcHttpResponderTransport.readBody`
bounded the request body correctly all along; the caller had no bound in the
other direction and took no policy at all.

From round 507 on the lens also asks what the work is FOR: is the buffering
needed on this path, does a guarantee (randomness, ordering, durability,
uniqueness) exceed what the code says it is for, and does the work achieve its
own purpose on this input?

## Ask

Between the byte arriving and the limit firing, how much is resident? Measure
`ProcessInfo.currentRss`/`maxRss` around one call — the differences here are
40x, so no statistics are needed. Measure bytes accepted before the error, not
whether the error arrives.

## Evidence

Confirmed repeatedly before the journal existed (imported from private memory in
the curate pass after round 234); every pre-journal instance is a real fix with a
sha: `RpcHttpCallerTransport` (e8c5bc9f) 192 MiB body -> RSS +756 MiB, +19 MiB
after; `RpcFrameMultiplexedChannel` (8a1282f0) one 256 MiB chunk past a 16 MiB
limit -> 256.2 MiB allocated, the cap bounded what was RETAINED, not ALLOCATED;
`bufferPreMethod` (a6440b9d, round 90) 250.7 MiB -> RSS +495.2 MiB,
unauthenticated on every channel transport; permessage-deflate (0af1eb44 /
948bd6da, rounds 74-75) 0.25 MiB -> 516 MiB (2071x), fixed by not OFFERING the
extension; `RpcGzipCodec` on the VM (round 107) 4.0 MiB -> +1873 MiB, ~470x,
because ISIZE is size MOD 2^32.

**Measured CLEAN — do not re-hunt:** the http2 caller (round 52, RSS +0 MiB);
message-level gRPC gzip through core's dart:io codec (rounds 76 and 108, status
13 in 48 ms); the compressed-flag variants. See
`../checked/C-16-http2-caller-inbound-buffers.md` and
`../checked/C-17-message-level-gzip.md`.

**Known live residual, deliberate:** a large UNCOMPRESSED WebSocket message is
buffered whole by dart:io, which exposes no `maxMessageSize` (searched
`_http/websocket.dart` and `websocket_impl.dart`). Amplification is 1:1, which
keeps it below the bar.

> **Two rules this class paid for.** In a regression test assert the error
> MESSAGE where the two layers produce different ones; where it is identical,
> RSS is the only witness, so give it a 4x margin and **page the source buffer in
> first**. And a bomb is defined by AMPLIFICATION (RSS per wire byte), not
> absolute RSS.

- **Round 236** — `BufferedBroadcastController` bounded its unlistened queue by
  EVENT COUNT (4096) only: 4096 x 16 MiB = 64 GiB admitted; +549 MiB with nothing
  subscribed, +58 MiB after. **A bound whose units are not the units of the
  damage is not a bound.** `../probes/P-15-pending-queue-dimension.md`
- **Round 279** — after 236 (events) and 245 (metadata weighing zero), metadata
  weighed its CHARACTERS; `["h1","v1"]` retains 97-111 bytes. 500 thin headers
  per frame: RSS 190.8 -> 20.8 MiB. **A dimension fixed is not a dimension
  closed**; build the shape that maximises damage per weighed byte.
  `../probes/P-29-metadata-weighs-characters.md`
- **Round 280** — a second family charged `payload?.length ?? 0`; the pre-method
  budget parked 4000 metadata frames at 789.2 MiB, 27.6 MiB fixed. **Two
  accountings of the same object drift apart the moment one is fixed**; grep for
  every OTHER expression measuring the same thing.
  `../probes/P-30-pre-method-budget-weighs-payload-only.md`
- **Round 350** — the six flow-control sites (`_fcOweConnection`,
  `_fcDischarge`, `_fcOnDelivered`) are right (281 refuted the asymmetry; HTTP/2
  exempts HEADERS). The real defect: `getMessagesForStream`'s per-stream
  `StreamController` had no limit at all. **Both halves of the lens can pass
  while the buffer has no limit at all.**
- **Round 489** — `RpcHttpResponderTransport` buffered the whole RESPONSE with no
  ceiling: 8192 KiB -> +40208 KiB, caller received 0 (status 8). **Read the
  direction the lens does NOT name**; **`received 0` is what turns a cost into a
  defect**; measure RSS with the largest arm FIRST (`+57664 KiB` vs `+11456
  KiB`). No catalog shape covers this; a `catalog/` candidate at the next curate.
  `../probes/P-128-what-an-http1-server-stream-retains.md`,
  `../rounds/489-buffering-bytes-the-caller-will-refuse.md`, B-98
- **Round 506** — `_decodeAt`'s metadata limit sat below the "keep buffering"
  return: `10485769` bytes held against 64 KiB, 160x; fix moved three lines.
  **A test asking "is it refused" passes against this defect**; yield between
  chunks; control is the same size without the limit applying; **check the
  sibling before designing the fix** (`frame_multiplexed_channel.dart`,
  `_refusedFrameHeader`, `closeOnOversizedFrame`).
  `../probes/P-144-how-much-is-held-before-the-refusal.md`,
  `../rounds/506-the-limit-that-waited-for-the-payload.md`, B-115
- **Round 507** — the reassembly buffer copied every chunk even when empty:
  `389.76 -> 191.45 us` per 1 MiB frame. **Measure the layer the lead names**;
  **a cost fix has no witness, only guards**; **report the honest row** (2x, not
  725x), keep a 64 B control, and state the reach (2566 MiB/s already).
  `../probes/P-145-what-the-receive-path-copy-costs.md`,
  `../rounds/507-the-copy-that-bought-nothing.md`, B-116
- **Round 509** — after round 505's `isEmpty` return, the `async*` wrappers still
  iterated an empty list: ~1.03 us per message, 19%. **After a "skip the work"
  fix, ask what still runs to discover there is nothing to do**; moving a
  decision from per-element to once is a contract change (test it); **two run
  sets are not a measurement** — report minima.
  `../probes/P-147-what-an-empty-middleware-wrapper-costs.md`,
  `../rounds/509-the-wrapper-around-an-empty-list.md`, B-118
- **Round 511** — `_uniqueToken`'s `Random.secure()` cost ~40 us of a ~97 us
  unary call, for ids `_strongRng`'s doc says are never secrets. **Check whether
  a GUARANTEE exceeds what the code says it is for**; ablate the thing and
  re-time the real path; a cost measured OUTSIDE the path is not a share of it.
  The change was one line, and it still belonged to the owner because it alters
  a documented security posture. `../probes/P-149-what-the-id-draws-cost-a-call.md`,
  `../rounds/511-forty-per-cent-of-a-call-is-entropy.md`, B-120
- **Round 512** — `isInternal`, "a bool read" in `CLAUDE.md`, cost `235.5 ns` vs
  `1.8 ns`; fixed to 12.6 ns. **Measure a guard against what it is CLAIMED to
  be**; the control is the claimed thing, literally, and says who paid; **a cache
  needs TWO ablations** (bypass it, then remove the invalidation).
  `../probes/P-150-what-the-log-guard-costs.md`,
  `../rounds/512-the-guard-that-was-not-a-bool-read.md`, B-121
- **Round 513** — gzip made a 32 B payload `42 -> 62` bytes. **Check the result
  rather than guess in advance** (a per-MESSAGE flag beats a threshold);
  **choose the probe's input from the claim's DIRECTION**; separate a lead's
  bundled claims. `../probes/P-151-does-compression-make-a-message-bigger.md`,
  `../rounds/513-the-compression-that-grew-the-message.md`, B-122
- **Round 519** — a Zone counted nine timers on a server stream before any
  deadline. **Put the whole system inside the instrument**; a measurement that
  makes a claim VANISH deserves suspicion; the no-deadline arm is the control;
  **a count is not a design** (fix declined, as in round 518).
  `../probes/P-156-how-many-timers-does-a-call-arm.md`,
  `../rounds/519-nine-timers-before-the-deadline.md`, B-127
- **Round 534** — `RpcWebSocketChannel`'s `_incoming` had no `onPause`: paused,
  5000 pulled, 0 delivered. **When the obvious reading is memory, reframe to
  DEMAND**; read both sides of the limit; grade a contract gap as one; check the
  layer below first. `../probes/P-167-does-pause-reach-the-socket.md`, B-138
- **Round 564** — `_halfClosedLocal` was the one map `health()` did not report.
  **A ledger with no observable cannot be measured**; **a zero is not evidence
  that something is empty** — ablate the REMOVALS, not just the adds.
  `../rounds/564-the-unreported-map-and-a-vacuous-zero.md`, B-184
- **Round 593** — INCONCLUSIVE: flow control ON vs OFF, both 20001 pulled, +34 vs
  +40 MiB. **A credit protocol bounds what you SEND, not what you READ**;
  residency far below what was offered, nothing refused, is a discard, not a
  bound. `../probes/P-210-what-the-transport-pulls-from-a-flooding-peer.md`
  (broken, fix named), `../rounds/593-the-pull-is-not-what-flow-control-bounds.md`,
  B-138
- **Round 594** — client-stream and unary bypass the per-stream bound: `19999`
  messages vs bidi's `1023`, unary RSS 1:1 with the peer. **List every PATH into
  the buffer, per shape.** `../probes/P-211-a-flood-into-a-stalled-handler.md`,
  `../probes/P-212-frames-after-a-unary-request.md`,
  `../rounds/594-the-two-buffers-the-stream-bound-never-saw.md`
- **Round 595** — per-stream caps let a peer choose the total (`8184` at 8
  streams, `16368` at 16); capped at the connection window: `4093`. **A cap on a
  shared total turns every un-released charge into an outage**; witness each
  RELEASE path first. `../rounds/595-the-product-the-per-stream-bound-left.md`
