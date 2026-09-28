---
status: closed (round 496)
round: 496
commit: 3d7979df
paths: [packages/core/rpc_dart/lib/src/core/parser.dart]
probe: P-134
reason: "closed — CONFIRMED quadratic across five scales, 16 MiB at 1515 ms -> 8 ms and the per-byte curve flat"
---

# B-105 — RpcMessageParser copies the whole unconsumed tail on every chunk

**Filed from the external audit of 2026-09-28** (core + transports, read in full,
transport findings re-checked against the code). Confidence from reading:
**high**. Nothing here was measured; the witness below is the first
thing a round owes this lead, and it may refute it.

While a message body is incomplete, each chunk costs `compact()` (copy the tail) plus `addBytes` (copy tail + chunk) — O(N^2/C) for an N-byte message in C-byte chunks: a 16 MiB message in 16 KiB DATA frames is ~1024 growing copies, gigabytes of memcpy; http2 feeds the parser exactly like that.

## The shape

`packages/core/rpc_dart/lib/src/core/parser.dart:36-50`:

```dart
void addBytes(Uint8List data) {
  if (readOffset == _bytes.length) {
    _bytes = Uint8List.fromList(data);          // comment says "reuse directly"
  } else {
    final merged = Uint8List(unconsumed + data.length);
    merged.setRange(0, unconsumed, _bytes, readOffset);
    ...
```

and `compact()` (`:60-65`) copies `_bytes.sublist(readOffset)` at the end of every
call. The header is read through a 5-byte `sublist` per message (`:190-195`). The
journal never examined this (`grep addBytes|quadratic` over `.claude/loop` is
empty apart from a lens).

## Why it matters

CPU and allocation blow-up on large messages over http2 (16 KiB frames), and on
any transport that hands the parser partial frames. The channel transports are
spared because `RpcFrameMultiplexedChannel` reassembles first.

## Witness a round would build

Micro-bench: feed a 16 MiB framed message in 16 KiB chunks; time and bytes
allocated. Then the same through an http2 pair, unary, 16 MiB request.

## Fix sketch

Once `expectedMessageLength` is known, allocate the body buffer once and fill it;
keep a list of chunks for the header phase; read the header with a
`ByteData.sublistView`. Also fix the "reuse incoming data directly" comment.

## Owner decision

—

## Closed (round 496) — quadratic confirmed across five scales

```
                      before                  after
 1 MiB in 65 chunks      7 ms  6.84 us/KiB     0 ms  0.00 us/KiB
 2 MiB in 129 chunks    34 ms 16.60 us/KiB     1 ms  0.49 us/KiB
 4 MiB in 257 chunks   122 ms 29.79 us/KiB     2 ms  0.49 us/KiB
 8 MiB in 513 chunks   350 ms 42.72 us/KiB     3 ms  0.37 us/KiB
16 MiB in 1025 chunks 1515 ms 92.47 us/KiB     8 ms  0.49 us/KiB
```

Chunk size FIXED, so the rising cost per byte is the message's doing. A single
timing could not have shown this; the curve is the evidence.

Fixed as the sketch's spirit asks, but not by its letter: instead of a special
body-phase buffer plus a chunk list for the header, a **capacity buffer grown
geometrically** — which is `RpcFrameMultiplexedChannel`'s own shape, with the same
two method names, one layer up. `compact()` now moves the tail rather than
reallocating.

**The sibling's second rule came with it and the sketch does not mention it**: that
channel checks its size limit BEFORE the append, because geometric growth would
otherwise let a peer past the bound make us allocate twice it first. The parser
checked after. Copying the growth without the ordering would have traded a CPU bug
for a memory one.

The stale comment the sketch names is gone: `"reuse incoming data directly"`
described a branch that copied.

## Left undone

- **The http2 end-to-end arm.** The parser is fed identically there and the cost
  is inside it, so the number would add transport noise to a settled question —
  but no claim about http2 throughput can cite this round.
- **Allocation peak**, unmeasured; only time. The pre-append limit check is what
  bounds allocation.
- **The 5-byte header `sublist`**, which the sketch also names. O(1) per message,
  invisible beside what was fixed, and every byte of this file's arithmetic is now
  load-bearing for correctness — a second change wants its own witness.
