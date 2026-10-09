---
file: packages/core/rpc_dart/.dart_tool/probe/b122_compression_threshold.dart
round: 513
commit: 3be26273
paths: [packages/core/rpc_dart/lib/src/core/compression.dart, packages/core/rpc_dart/lib/src/rpc/streams/base_processor.dart, packages/core/rpc_dart/lib/src/rpc/streams/unary/caller.dart, packages/core/rpc_dart/lib/src/rpc/streams/unary/responder.dart]
status: valid
---

# P-151 — does compression make a message bigger?

## Why it exists

Two claims in one lead, needing different instruments: that compression with no
threshold grows small messages, and that a zero-copy transport compresses across an
in-process boundary. The first is bytes on the wire, the second is a header the
caller does or does not set. The lead's own confidence was `medium`, and one of the
two turned out to be wrong.

## The harness

Frame sizes read at the byte channel, where a DATA frame's declared length is the
payload actually sent. Sizes swept from 32 B to 4 KiB, with compression off and on,
so each row is a paired comparison of the same payload.

**The payload's compressibility is the axis that matters, and the first version of
this probe got it backwards.** It used `'a' * n` — maximally compressible — while
testing whether compression makes messages BIGGER. That is the case least likely to
grow; it reported a saving at 32 B and would have refuted the lead. The payload is
now deterministic structureless text from an xorshift, with the repeated-character
case kept as a control.

The second claim is a real call over `memoryPair` with compression enabled, reading
the `grpc-encoding` the responder actually sends back.

## The numbers (round 513)

Incompressible, request frame bytes:

```
          before            after
  32 B    42 -> 62          42 -> 42
  64 B    74 -> 94          74 -> 74
  96 B   106 -> 126        106 -> 106
 128 B   138 -> 155        138 -> 138
 192 B   202 -> 206        202 -> 202
 256 B   267 -> 253        267 -> 253
 512 B   523 -> 448        523 -> 448
4096 B  4107 -> 3138      4107 -> 3138
```

Compressible, unchanged by the fix:

```
  32 B    42 -> 33
4096 B  4107 -> 51
```

Zero-copy arm, before and after: `response grpc-encoding: NONE (identity)`.

## Measures

Bytes in the DATA frame, paired per payload. Not CPU: the lead names CPU too, and
nothing here measures it.

## Control

**The repeated-character rows.** They show the rig reports a saving when one exists
— 4107 → 51 is unmistakable — so a row where the compressed size is LARGER is the
payload, not the instrument.

They also carry the design argument: gzip beats plain even at 32 B when the bytes
repeat, so a size threshold would discard a real saving. That row is why the fix
compares sizes rather than applying a cutoff.

**The `compression OFF` column is the other control**, and it is what makes each row
a paired comparison rather than an absolute number to be interpreted.

## What it establishes, and what it does not

Establishes: compression applied unconditionally grew incompressible payloads up to
roughly 200 bytes — 48% at 32 B — with the crossover between 192 B (+4) and 256 B
(−14). After comparing and keeping the smaller form, no size grows and every saving
is kept.

**Refutes the second claim.** On `memoryPair`, where both sides report
`supportsZeroCopy: true`, the response comes back `identity`. The responder does not
gzip across the in-process boundary, before or after.

Does NOT measure CPU, which is half of the lead's "grow and cost CPU". Comparing
sizes still pays the compression work on payloads that end up sent plain, so the CPU
half is not addressed at all — only the bytes.

Does NOT cover the isolate transport specifically. `memoryPair` is the zero-copy
shape available in-process; a real isolate pair was not run.

## Reading

rpc_dart — **its first version would have refuted a true claim**, and the
record keeps why: it used `'a' * n` as the payload while testing whether
compression makes messages BIGGER, which is the case least likely to grow.
Incompressible input is what tests growth; the repeated-character rows survive
as the control, and they carry the design argument too — gzip beats plain even
at 32 B when bytes repeat, so a size threshold would discard a real saving.
The `compression OFF` column makes every row a paired comparison rather than
an absolute to be interpreted. Measures bytes only: the lead's CPU half is not
instrumented here at all.
