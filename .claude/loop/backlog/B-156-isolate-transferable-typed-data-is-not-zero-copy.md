---
status: closed (round 578)
round: 578
commit: 1508ed40
release: changelog
paths: [packages/transport/rpc_dart_isolate/lib/src/isolate_transport.dart]
probe: P-199
reason: "cost — CONFIRMED for small frames and REFUTED for large ones: the transfer is up to 46% slower below ~128 KiB and up to 35% FASTER at 256 KiB and above, so the sketch's 'or all' would have cost 23% on a 1 MiB frame. Fixed with a threshold"
---

# B-156 — isolate: TransferableTypedData.fromList copies, contrary to the class doc

**Filed from the external audit of 2026-09-28** (core + transports, read in full,
transport findings re-checked against the code). Confidence from reading:
**high**. Nothing here was measured; the witness below is the first
thing a round owes this lead, and it may refute it.

The doc says bytes cross without a copy; `TransferableTypedData.fromList([payload])` copies once — the same as sending the Uint8List — and adds a native allocation and finaliser to every frame, most of which are tiny grants and headers.

## The shape

`packages/transport/rpc_dart_isolate/lib/src/isolate_transport.dart:43-44` vs `:95`.

## Why it matters

A net cost per small frame and a false claim.

## Witness a round would build

Frames/s for 32-byte payloads, TTD vs plain Uint8List.

## Fix sketch

Send Uint8List for small payloads (or all), fix the doc.

## Outcome (round 578) — confirmed small, REFUTED large

`../rounds/578-the-transfer-that-cost-more-than-it-saved.md`. Bench `P-199`.

```
  size      TTD us/frame   Uint8List us/frame
        32          2.71                 2.34
      1024          2.66                 2.33
     65536         11.26                 7.87
   131072         20.44                14.03
   262144        103.71               160.67
   524288        191.85               265.50
  1048576        383.08               486.63
```

**The claim holds below ~128 KiB and inverts above it.** The lead asked for one size — 32 bytes — which
would have confirmed it and hidden half the answer; the columns CROSS between 128 and 256 KiB. The
sketch's parenthetical "or all" would have cost 23% on a 1 MiB frame.

Fixed with a threshold at 256 KiB, the first measured size where the transfer wins. **The receive side
needed no change**: `_materializeBytes` already accepts either shape, which is what made this a one-line
send-side fix. The doc now says what the code does and the constant carries the numbers.

Not established: the numbers are from RAW ports carrying the two expressions the channel picks between,
so the comparison is sound but the absolute figures are not a frame's true cost through the transport.
The crossover is bracketed, not located. And the premise that this transport mostly carries small frames
comes from reading what it sends, not from counting a workload.

## Owner decision

—
