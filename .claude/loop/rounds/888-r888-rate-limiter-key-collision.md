---
round: 888
verdict: FIXED
packages: [rpc_dart]
lens: RPC-27
bench: P-340 — new
commit: yes
severity: S1 — "memory or CPU a peer or ordinary use can grow without bound"
release: changelog
---

# Round 888 — a rate limiter whose per-key store a peer can make walk

## Target

The continuation of round 887's class (L-12: sweep the class, not the sample) —
a `Map` keyed by peer-controlled strings. `RpcRateLimiter`'s per-key counter
store keys by `userKey` (from `_keyExtractor`, "a client-supplied userId" per
its own dartdoc). Open lead B-308 named the LRU `keys.first` walk on this file
but was never measured. The hash-collision angle (887) had no record here.

## Hypothesis

The dynamic store is a `Map<String, Map<String, _RateLimitCounter>>` used as an
LRU: a hit does `remove(key)` + re-insert, a new key at the cap evicts
`store.keys.first`. The key is attacker-controlled, so (a) distinct rotating
keys make `keys.first` walk the tombstones (B-308), and (b) keys that share a
`String.hashCode` make every `store[key]`/remove/insert walk the collision
chain (887). `maxTrackedKeys` bounds the key count, not the per-op cost. Fails
if the per-request cost is flat as the store fills.

## Before

P-340 (`r888_ratelimiter/probe.dart`), cap=20000, 2000 requests, us/request:

```
control  (repeat hot key)      1.04
distinct (rotate, B-308 walk)  2.66   x2.6
collide  (rotate, 887 chain)   230.49 x222.4
```

The collision path is the severe one: every request pays O(chain), and the
chain is as long as the store, bounded only by `maxTrackedKeys` (default
100000, 5x this). It is persistent — paid on every call while the store holds
the colliding keys — on the component meant to absorb floods. Reachable from
any `keyExtractor` that returns a client-controlled value, which is its normal
per-client use. The distinct arm's 2.6x is NOT the B-308 walk: it is unchanged
after the fix (2.63 us), so it is the cost of a new key and counter. At this
cap the walk does not show.

## Mechanism

RPC-27, a bound in the wrong unit: `maxTrackedKeys` counts keys, the attack
spends CPU reaching one. Dart's `Map` walks the probe chain of same-hashCode
keys on lookup, remove and insert.

## After

The three stores become `_KeyedLruStore`, keyed by a per-store SALTED
one-at-a-time hash of the userKey (salt from `Random.secure()`, 32 bits in two
16-bit draws, every shift under 2^53 for dart2js). Without the salt a peer
cannot precompute keys that share a bucket, so collision chains stay at their
honest length (~1). Eviction is an O(1) LRU over an intrusive doubly-linked
list, so there is no `keys.first` tombstone walk either. `maxTrackedKeys` is
now the store's capacity and the `_maxTrackedKeys` field is gone.

P-340 after: collide 1.55 us (222x -> 1.3x), distinct 2.63, control 1.16. The
collision cost is gone; the distinct-rotate cost is the unavoidable work of a
genuinely new key.

Rare, fail-safe caveat: two userKeys whose salted hashes collide (unpredictable
to the peer, ~1 pair in 100000) land in one bucket but keep separate nodes
(the node stores the string and lookup compares it), so they are NOT merged.

## Canary

`_hash` switched in place to `return key.hashCode` (unsalted, the old
String-hashCode keying): P-340's collide arm returns to 242.61 us (211x), the
colliding keys piling into one bucket again. Restored: 1.55 us.

Correctness guards (`audit_rate_limiter_colliding_keys_test.dart`, VM-only —
the collision construction is VM-hash-specific):
- keys that share a hashCode get independent limits (not merged into one
  counter);
- LRU eviction holds across colliding keys (the oldest is evicted, a recent one
  stays rate-limited).
Both pass on the fix; they are GUARDs of the new structure's correctness, not
the perf canary (which is P-340 above).

## Gate

`melos run analyze`, `test:unit:quiet --no-select`, `format:check`,
`license:check`, `api:check`: green. The public API is unchanged — the new
`_KeyedLruStore`/`_LruNode` are private and the constructor signature is the
same. The new guard is VM-only, skipped under `-p node`.

`-p node` / `test:web` was NOT run, though the config asks for it on a core
change, and the claim made here that the salt was platform-agnostic was
wrong: `Random.secure()` throws on node, so every `RpcRateLimiter` failed to
construct there (45 failures). Found by round 890's `test:web` and fixed in
its own commit with a fallback to `Random()`.

## Siblings

Not a transport contract. `RpcRateLimiter` is one interceptor used by any
`RpcResponderEndpoint` over any transport, so the one fix covers them all. The
sibling to this round is round 887: the same RPC-27 class (a String-keyed map a
peer fills with colliding keys) on the CBOR decoder, fixed there by a per-map
collision cap, here by a salted hash — the decoder must refuse, the limiter
must keep serving.

## Not fixed

- B-308 closes because its code is gone (the LRU no longer has a `keys.first`),
  not because a walk was measured: P-340 never saw one at cap 20000.
- Web: the salt works on dart2js, but the collision cost was never measured
  there (dart2js hashes strings differently); a lead if it matters.

## Links

RPC-27; round 887; B-308; L-12; P-340.
