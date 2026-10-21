---
round: 887
verdict: FIXED
packages: [rpc_dart]
lens: RPC-27
bench: none — the arm/control decode sweep is probe.dart (r887_hashdos/, named in ## Before); promoted to the unit witness colliding_map_keys_are_refused_test.dart
commit: yes
severity: S1 — "memory or CPU a peer or ordinary use can grow without bound"
release: changelog
---

# Round 887 — a CBOR map of colliding keys decodes quadratically

## Target

The CBOR map decoder, picked up from a security-audit session that stopped on
`kv_cd_06` (does the VM's String.hashCode reproduce a Jenkins one-at-a-time
model). It does: `bits=30 match 1000/1000`, so String.hashCode is an unseeded
30-bit OAAT hash and a peer can precompute keys that share it. No journal
record spoke of hash collisions before — `find 'collision'` is all stream-id
reuse (RPC-03), `find 'hash'` is the rate-limiter LRU. Records weighed:
round 803 / B-275 (the item budget `maxDecodedItems`), round 783 (CBOR decodes
many bytes per wire byte) — both bound COUNT, neither bounds the cost of
building the map.

## Hypothesis

`_FastCborReader._readMapFast` builds a `Map<String,dynamic>` with
`result[key] = value`. Dart's compact map compares a new key against every
resident key of equal hashCode, so N keys that all share one hashCode cost
O(N^2). `maxDecodedItems` (default 1M) caps N but not the per-insert chain, so
one message within the byte and item limits blocks the event loop for a long
time. The decode runs in `_decodePeerMessage` before any interceptor, on both
inbound paths. Fails to hold if Dart's Map is collision-resistant (a flat
ratio as N grows).

## Before

`probe.dart`: one map of N entries, decode time, arm vs control. Arm keys are a
per-slot OAAT multicollision (each slot a pair of blocks interchangeable from
the running state), so all N keys share one hashCode; control is `key_$i`.

```
N        arm_ms    ctrl_ms   ratio
2000       18.99      1.05    18.1
4000       48.81      0.40   121.7
8000      191.24      0.81   237.0
16000     813.83      1.78   317.7
32000    3269.25      3.94   828.7
64000   13369.54      7.70  1736.8
```

Arm is a clean O(N^2): ~4x per doubling. One 6.3 MB message (N=64000) blocks
the single-threaded event loop for 13.4 s; the control is flat. A 16 MiB
payload (within `maxMessageLengthBytes`) extrapolates to 80+ s. The construction
is confirmed correct in `verify.dart`: N=32000 distinct strings, one hashCode.

Reachability: `base_processor._decodePeerMessage` decodes under the item
budget, called from `base_processor_responder._processDataMessage` (hostile
client to server) and `base_processor_caller._processResponseData` (hostile
server to caller). Every codec pays it: `RpcCodec.deserialize` is
`_fromJson(CborCodec.decode(bytes))`, so the whole wire map is built before a
field is read. Pre-auth (the dartdoc of `maxDecodedItems` already says
"decoded before any interceptor runs").

## Mechanism

A limit counted in the wrong unit (RPC-27): `maxDecodedItems` bounds items, the
attack spends CPU. The quadratic is Dart's Map walking an O(chain) probe of
same-hashCode keys on every insert.

## After

`_readMapFast` caps keys of one hashCode per map at `_maxKeyHashCollisions` (16)
via a per-map `Map<int,int>` counter, and refuses past it with
`CborKeyCollisionException` (a `FormatException`, like `CborItemLimitException`;
`_decodePeerMessage` answers it RESOURCE_EXHAUSTED). Maps at or below
`_collisionTrackingThreshold` (64 entries) skip the counter — worst case
64^2 comparisons, cheap — so the common small map pays nothing. Total decode is
now O(items): any bucket is bounded at 16, and spreading across many buckets
stays under items*16.

`canary.dart`: the N=64000 arm is refused in 2 ms (was 13369 ms); the control
decodes unchanged (22 ms for 64000 distinct keys, the counter's only cost); a
5000-key distinct map and nested small maps decode fine.

Worst case after the cap: items * 16 comparisons ~ 100 ms at the 1M item
ceiling, refused rather than sustained.

## Canary

Guards in `colliding_map_keys_are_refused_test.dart` (VM-only: the construction
reproduces the VM hash):

- the construction really collides (100 distinct strings, one hashCode) — fails
  loudly if String.hashCode ever changes, so the rest cannot false-pass.
- a map past the cap is refused with "keys of one hashCode", in < 200 ms.
- 16 colliding keys among distinct filler (> 64 entries, so tracked) decode;
  the 17th is refused — the per-hashCode boundary.
- GUARDs: a 5000-key distinct map and an ordinary nested small map still decode.

The definite-map `_chargeKeyHash` call commented out: `a map past the cap is
refused, and cheaply` and `16 keys of one hashCode are allowed, the 17th is
not` go red, "Expected: throws <Instance of 'FormatException'> ... Actual:
<Closure: () => Map<String, dynamic>>" (`+3 -2`). Restored: all five green.
The indefinite-map branch has no witness of its own.

## Gate

`melos run analyze`: green, 21 packages + rpc_dart_wasm. `melos run
test:unit:quiet --no-select`, `melos run format:check`, `melos run
license:check`: green. `melos run api:check`: public API matches (the new
exception is internal, not exported past `show CborCodec`). The new test VM-only
and skipped under `-p node` by construction; the fix itself is
platform-agnostic (it caps whatever hashCode the platform produces).

## Siblings

The decoder is shared, not a per-transport contract. `_decodePeerMessage` is
the one decode path for every transport and both directions, so the single fix
covers caller and responder on channel, http, http2, websocket, isolate and
wasm alike. Web (dart2js): the same code runs; dart2js hashes strings
differently so the VM collision set does not transfer, but the cap bounds
dart2js's Map chains the same way. Not measured on web — a lead if it matters.

## Not fixed

—

## Links

RPC-27, RPC-17; round 803 / B-275 (the item budget); kv_cd_06 (the hash model);
L-12 (sweep the class — the cap bounds every map, not the sampled sizes).
