---
round: 783
verdict: DEFERRED
packages: [rpc_dart]
lens: RPC-27
bench: P-278 — new
commit: yes
release: none
severity: S1
---

# Round 783 — cbor decodes seventy bytes per wire byte before auth

## Target

The network-audit skill's `known codec` sweep, methods.md §3 ("a decoded
Map weighs far more than its CBOR"). `loop.py find 'decoded object size
amplification CBOR empty arrays'` and `find --path .../special_cbor.dart`
named depth, RFC edges, typed lists and web bytes, never breadth or decoded
size. RPC-27 is the lens: the message is bounded in bytes; a byte's decoded
weight is the peer's choice.

## Hypothesis

A message of many one-byte items decodes to many heap objects, so the
16 MiB default admits a decode of gigabyte scale, and it runs before any
interceptor can refuse the call.

## Before

P-278:

```
  CborCodec.decode, 16 MiB          heap growth   per wire byte   decode
  one byte string                   +16 MiB       1.0             2 ms
  16 Mi empty maps (0xA0)           +1148 MiB     71.8            1047 ms

  through a responder that refuses every call in an interceptor
  bytes      x1   max rss 75 MiB     7 ms      decodes 1
  emptyMaps  x1   max rss 1309 MiB   979 ms    decodes 1
```

Probe: `packages/core/rpc_dart/.dart_tool/probe/cbor_amplification_e2e.dart`

## Mechanism

`RpcCodec.deserialize` calls `CborCodec.decode`, which builds one Dart
object per CBOR item with no count, only a depth guard. The responder
deserializes the request before the middleware and interceptor chain, which
receives `TRequest` already built.

## After

n/a.

## Canary

n/a.

## The verdict questions

1. Yes: the arms differ in payload item count only; wire size, path and
   refusal are the same.
2. Yes: 75 MiB against 1309 MiB.
3. Library side: the responder's own decode, counted by a wrapper codec
   (`decodes`), in the process that runs it.
4. n/a.
5. n/a.
6. n/a.
7. DEFERRED for an owner decision: any item budget refuses some legitimate
   payload, so its default and where it is configured are the owner's. The
   severity is at the top of the skill's ladder (pre-auth, 72:1, the isolate
   blocked), which is why the lead is ranked first.
8. Not measured, not ruled out: dart2js and dart2wasm; the generator's
   codecs; a real socket instead of the channel pair.
9. None.
A1. One process; caller and responder are separate endpoints, the
    responder with the default `RpcSecurityPolicy`.
A2. Volume.
L1. The only refusal is the stand-in interceptor's UNAUTHENTICATED, and the
    point is that it comes after the decode.

## Gate

n/a — no code change.

## Not fixed

B-275, awaiting the owner.

## Links

Lens `../lenses/RPC-27-a-bound-counted-in-the-wrong-unit.md`.
Probe `../probes/P-278-cbor-decode-cost-per-wire-byte.md`.
Lead `../backlog/B-275-the-cbor-decoder-has-no-item-budget.md`.
Negative `../checked/C-68-the-lockfiles-have-no-known-advisories.md`, taken
in the same audit pass (KV-G-02).
