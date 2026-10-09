---
round: 785
verdict: DEFERRED
packages: [rpc_dart]
lens: RPC-27
bench: P-278 — reused
commit: yes
release: none
---

# Round 785 — fifteen KiB of gzip decode to a gigabyte

## Target

The network-audit skill's KV-CD-04, message-level decompression, taken
right after round 783 because it composes with that round's mechanism:
gzip is accepted with nothing configured (the registry ships
`identity,gzip` on the VM, rounds 456 and 543), and
`maxMessageLengthBytes` bounds the decompressed size. The question is how
few wire bytes reach the 16 MiB that round 783 measured as a gigabyte.

## Hypothesis

A gzip-compressed request of empty CBOR maps costs the responder what the
uncompressed one does, from a few KiB on the wire.

## Before

P-278's e2e bench, extended with `compressionEnabled` on the caller and a
listener on the server transport summing payload bytes and reading
`grpc-encoding`:

```
  arm                 on the wire   encoding   max rss    took      decodes
  emptyMaps, plain    16383 KiB     -          1269 MiB   1136 ms   1
  emptyMaps, gzip     15 KiB        gzip       1296 MiB   1021 ms   1
  bytes, gzip         15 KiB        gzip       92 MiB     57 ms     1
```

Every call was refused UNAUTHENTICATED by the interceptor, after the
decode.

Probe: `packages/core/rpc_dart/.dart_tool/probe/cbor_amplification_e2e.dart`

## Mechanism

The parser decompresses up to `maxMessageLengthBytes`, which is the bound
working as designed; B-275's decode then builds about 72 heap bytes per
decompressed byte. The two ratios multiply: about 86,000 heap bytes per wire
byte, and about one second of the responder's isolate per 15 KiB request.

## After

n/a.

## Canary

n/a.

## The verdict questions

1. Yes: `bytes, gzip` against `emptyMaps, gzip` differ in item count only;
   `emptyMaps, plain` against `emptyMaps, gzip` differ in the encoding only.
2. Yes: 92 MiB against 1296 MiB at the same 15 KiB.
3. Library side: the payload bytes counted on the server transport's
   incoming stream; the decode counted in the responder.
4. n/a.
5. n/a.
6. n/a.
7. DEFERRED with round 783's lead, whose decision this does not change,
   only its price: a bound on decoded items is still the fix and its default is
   still the owner's. Rank stays 1.
8. dart2js was not measured: there the built-in gzip is not registered
   (round 543), so this path needs an application-registered codec.
9. None.
A1. One process; caller and responder are separate endpoints, the
    responder with the default policy and default compression registry.
A2. Volume.
L1. The refusal is the stand-in interceptor's, after the decode.

## Gate

n/a — no code change.

## Not fixed

B-275, awaiting the owner, now with this price.

## Links

Lens `../lenses/RPC-27-a-bound-counted-in-the-wrong-unit.md`.
Probe `../probes/P-278-cbor-decode-cost-per-wire-byte.md`.
Lead `../backlog/B-275-the-cbor-decoder-has-no-item-budget.md`.
Round `783-cbor-decodes-seventy-bytes-per-wire-byte-before-auth.md`.
