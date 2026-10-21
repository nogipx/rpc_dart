---
status: closed (round 888)
round: 888
commit: 43d2d3a8
paths: [packages/core/rpc_dart/lib/src/resilience/rate_limiter.dart]
probe: P-340
reason: closed — round 888 removed the code: the store is now an O(1) intrusive-list LRU with no keys.first. The walk itself was never seen: P-340's distinct-key arm is 2.66 us before and 2.63 us after at cap 20000, so its 2.6x over the control is the cost of a new key, not the walk.
rank: 7
---

# B-308 — rate limiter lru first walk

`_getDynamic` keeps per-key counters in an insertion-ordered map and uses it
as an LRU: every hit removes the key and re-inserts it, and a new key at the
cap evicts `store.keys.first`. In the VM, `first` on a linked hash collection
walks the slots its removals left behind. The same shape (a `Set<int>`
evicting `remove(first)`, cap 1024) cost about 870 ns per operation against
about 40 ns for a hash set with a queue, and three such sets were 10% of a
unary call's CPU before step 4 replaced them with `RpcRecentIds`.

The key is client-controlled (`_keyExtractor`), so a client rotating keys at
the cap pays the walk on every request, while hot keys pay the remove and
re-insert on every request.

## Next step

Measure: a limiter at `_maxTrackedKeys`, requests with a fresh key each, time
per request; control: the same with keys that repeat. Then the same
measurement with an LRU that does not walk (a hash map plus an order queue,
or a `LinkedList`).

## Owner decision

—
