---
round: 620
verdict: FIXED
packages: [rpc_dart]
lens: RPC-15
bench: P-222 — new
budget: probes 2/5, canaries 1/5
commit: yes
release: changelog
---

# Round 620 — a floor the format sets

## Target

B-206: comparing sizes fixed compression growing small messages, and paid for
it with a compress on every payload, including the ones sent plain. Also two
`Uint8List.fromList` copies around dart:io's gzip.

## Hypothesis

The discarded compress is a visible share of a message's cost.

## Before

```
          incompressible        compressible
  16 B     17.86 us  plain       16.79 us  plain
  64 B     20.41 us  plain       19.50 us  gzip
 256 B     27.96 us  plain       19.47 us  gzip
   1 KiB   36.35 us  plain       20.18 us  gzip
```

About 17 us is fixed zlib set-up, so the cost is four streamed messages' worth
(4.4 us each) on a payload that is then sent unchanged. `P-222`.

## Control

The form sent, which must not change at any size.

## Mechanism

There are two answers to "skip the compress". A size threshold trades the real
saving on small compressible payloads for CPU, and the code documents why it
chose not to. That one needs a number that suits only some traffic, and the
owner left it alone (2026-10-02). The format's own floor needs no number: a gzip
member is at least 20 bytes (10-byte header, 2-byte empty final block, 8-byte
trailer, RFC 1952), so a payload of 20 bytes or fewer can never be sent smaller
compressed.

## After

```
  16 B      0.11 us  plain        0.04 us  plain
  20 B      0.03 us  plain        0.03 us  plain
  21 B     19.12 us  plain       18.90 us  plain
  64 B     19.69 us  plain       18.45 us  gzip
```

`compressIfSmaller` sends a gzip payload of at most 20 bytes plain without
compressing it, for any codec registered under `gzip`, since the floor is the
format's. dart:io's gzip result is used as is when it is already a `Uint8List`
(the two copies). The 21-byte and larger rows are unchanged by design.

## Canary

Floor switched off: `a payload no longer than gzip's floor is not compressed`
fails with `Expected: <0>, Actual: <1>`. `GUARD: the floor never changes what is
sent` checks every length from 0 to 40 bytes, zero-filled and random, against
compressing every payload.

## Gate

`melos run analyze`, `melos run test:unit --no-select` (rpc_dart +1929,
compression +31), `melos run format:check`, `melos run license:check` — green.

## Not fixed

The fixed 17 us on payloads from 21 bytes up to where compression starts to
win. That is the threshold trade-off the owner kept as documented.

## Links

Lead `../backlog/B-206-comparing-sizes-costs-cpu-and-two-copies.md` — closed.
Bench `../probes/P-222-what-a-discarded-compress-costs.md` — new.
Lens `../lenses/RPC-15-remeasure-own-record.md` — `applied: [..., 620]`.
Test `packages/core/rpc_dart/test/core/a_payload_gzip_cannot_shrink_is_not_compressed_test.dart`.
