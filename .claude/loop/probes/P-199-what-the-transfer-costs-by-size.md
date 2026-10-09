---
file: packages/transport/rpc_dart_isolate/.dart_tool/probe/b156_ttd_vs_uint8list.dart
round: 578
commit: 1508ed40
paths: [packages/transport/rpc_dart_isolate/lib/src/isolate_transport.dart]
status: valid
---

# P-199 — what does TransferableTypedData cost, by size?

## Why it exists

B-156 asked for "frames/s for 32-byte payloads, TTD vs plain Uint8List" — one size, which would have
confirmed the lead and hidden the rest of the answer. A copy's cost is a FUNCTION of size, so the arm is a
sweep.

## The harness

A worker isolate that echoes, materialising a `TransferableTypedData` the way the transport's receive side
does — `materialize().asUint8List()` — so the receiver's share of the cost is inside the arm rather than
outside it.

Round trips over a bare `SendPort`/`ReceivePort` pair, timing the two expressions the channel chooses
between: `TransferableTypedData.fromList([payload])` and `payload`. **`fromList` is INSIDE the timed loop**,
because where the copy happens is the whole question.

One completer per round trip rather than `package:async`'s `StreamQueue`, which this package does not
depend on. 200 warm-up frames discarded; three runs per size reported as the MINIMUM, since noise on this
machine only ever adds time (round 509's statistic).

## The numbers (round 578)

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

## Measures

Microseconds per round trip, by payload size, for each of the two send shapes. A round trip rather than a
one-way send, because a one-way measurement would charge the sender for a copy the receiver pays for.

## Control

**Each size is the other arm's control**, which is what makes the sweep rather than the single size the
point: the two columns cross between 131072 and 262144. Below it the plain list is up to 46% faster, above
it the transfer up to 35% faster — so the lead's "or all" would have cost 23% on a 1 MiB frame.

The warm-up and the minimum-of-three are what stop a single slow run reading as a crossing.

## What it establishes, and what it does not

Establishes that `TransferableTypedData` is a net LOSS below ~128 KiB and a net WIN at and above 256 KiB,
so a flat choice is wrong whichever way it is made.

**Does NOT measure through the transport.** These are raw ports carrying the two expressions the channel
picks between, so the comparison is sound, but the transport's own per-frame overhead sits on neither arm
and the absolute figures are not a frame's true cost.

Does NOT locate the crossover, only bracket it: 128 KiB favours the list, 256 KiB the transfer, and the
threshold sits at the first measured winner rather than the true crossing.

Does NOT weigh the frame MIX. That this transport mostly carries small frames comes from reading what it
sends, not from counting a workload.

## Reading

rpc_dart_isolate — **a SWEEP, because a copy's cost is a function of size and
the lead asked for one point**: `32 B 2.71 vs 2.34`, `128 KiB 20.44 vs 14.03`,
then inverting at `256 KiB 103.71 vs 160.67` and `1 MiB 383.08 vs 486.63`.
Each size is the other arm's control, and the two columns cross between 128
and 256 KiB. `fromList` is INSIDE the timed loop, which is the whole question;
the worker materialises the TTD so the receiver's share is in the arm; minimum
of three runs after 200 warm-up frames. Does NOT measure through the transport
— raw ports carrying the two expressions the channel picks between, so the
comparison is sound and the absolutes are not a frame's true cost
