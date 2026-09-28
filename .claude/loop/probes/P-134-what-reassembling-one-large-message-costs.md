---
file: packages/core/rpc_dart/.dart_tool/probe/b105_parser_quadratic.dart
round: 496
commit: 3d7979df
paths: [packages/core/rpc_dart/lib/src/core/parser.dart]
status: valid
---

# P-134 — what reassembling one large message costs

## Why it exists

`RpcMessageParser` is fed partial frames by http2, 16 KiB at a time. The question
is not "is it slow" but whether the cost per byte is CONSTANT — and a single
timing cannot answer that.

## The harness

One framed message fed in 16 KiB pieces, at five message sizes doubling from
1 MiB to 16 MiB, with the chunk size FIXED so the only variable is how much is
already buffered. Reports us/KiB, which is flat for linear work and doubles with
the message for quadratic.

Two details that matter:

- the pieces are `Uint8List.sublistView`, not copies, so what is timed is the
  parser's own work rather than the harness slicing;
- a warm-up run at 256 KiB first, or the first measured scale pays the JIT for
  the others and the curve tilts the wrong way.

## The numbers (round 496)

```
                      before                  after
 1 MiB in 65 chunks      7 ms  6.84 us/KiB     0 ms  0.00 us/KiB
 2 MiB in 129 chunks    34 ms 16.60 us/KiB     1 ms  0.49 us/KiB
 4 MiB in 257 chunks   122 ms 29.79 us/KiB     2 ms  0.49 us/KiB
 8 MiB in 513 chunks   350 ms 42.72 us/KiB     3 ms  0.37 us/KiB
16 MiB in 1025 chunks 1515 ms 92.47 us/KiB     8 ms  0.49 us/KiB
```

## Measures

Microseconds inside `parser(...)`, divided by message size. The RATIO across
scales is the finding; the absolute numbers are machine-specific and the record
keeps them only so a later run can tell a regression from a faster laptop.

## Control

The curve is its own control: five points at one chunk size, so "the parser is
slow" and "the parser is quadratic" give different shapes. 6.84 -> 92.47 us/KiB
is a 13.5x rise in cost per byte across a 16x rise in size.

The ablation confirms it from the other side — exact-fit growth restored gives
`37.5x` the time for 8x the bytes where the fixed version gives under 2x.

## What it establishes, and what it does not

Establishes: reassembly was quadratic in message size, and geometric growth makes
it flat.

Does NOT measure it through an http2 pair, which is what the lead asked for
second. The parser is fed identically by that path (16 KiB DATA frames) and the
cost is inside the parser, so the end-to-end number would add transport noise to
a settled question — but it is not measured, and a claim about end-to-end http2
throughput cannot cite this.

Does NOT measure allocation, only time. The `maxBufferedBytes` bound is what
limits allocation, and the round moved its check BEFORE the append for that
reason; the peak itself is unmeasured.
