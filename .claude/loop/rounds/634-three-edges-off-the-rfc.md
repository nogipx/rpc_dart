---
round: 634
verdict: FIXED
packages: [rpc_dart]
lens: RPC-07
bench: none — the witness decodes hand-made bytes and round-trips -0.0 on VM and node
budget: probes 1/5, canaries 1/5
commit: yes
release: changelog
severity: S2
---

# Round 634 — three edges off the RFC

## Target

B-240, from the audit of 2026-10-02: three places where the CBOR codec parts
from RFC 8949.

## Hypothesis

`decode` returns after the first data item without looking at what follows;
unassigned simple values come back as the int of their number; and on dart2js
`-0.0` is an `int`, so the integer encoder sends it as `0`.

## Before

```
a1616101 a1616202 (two maps)        decode -> {a: 1}, the second dropped
0001                                decodeUnsafe -> 0
a16176f0 (simple 16)                -> {v: 16}
a16176f818 (not well-formed)        -> {v: 24}
RpcDouble(-0.0) on node             -> 0, sign lost (VM keeps it)
```

## Control

A truncated item is refused, a single item decodes, false/true/null decode, and
the VM keeps `-0.0`; node decoding the VM's bytes keeps it too, so only the web
encoder dropped it.

## Mechanism

Each is a check that was never made: the reader's offset against the input
length, the simple-value range against the values that mean something here, and
zero's sign in the encoder's "not really an int" test, which already sent NaN,
infinities and out-of-range values to the double encoder.

## After

`decode` and `decodeUnsafe` refuse bytes after the item (`N bytes after the CBOR
data item`); unassigned simple values in either form are refused; `-0.0` is
encoded as a double on both runtimes. The witness passes on VM and node;
`test/serializers` 144 green on each.

## Canary

The before table is the same witness against the old reader and writer.

## Gate

`analyze` and `format` on rpc_dart green, `melos run test:unit` and `melos run
test:web` green (exit 0 each).

## Not fixed

`cbor_parity_test.dart` pinned "extended simple value 200 decodes to 200"; that
arm now expects the refusal. A peer that relied on either leniency is refused
now: a CHANGELOG line.

## Links

Lead `../backlog/B-240-three-cbor-edges-off-the-rfc.md` — closed.
Lens `../lenses/RPC-07-web-as-separate-runtime.md` — `applied: [..., 634]`.
Tests `packages/core/rpc_dart/test/serializers/cbor_items_are_well_formed_test.dart`,
`packages/core/rpc_dart/test/serializers/cbor_parity_test.dart`.
