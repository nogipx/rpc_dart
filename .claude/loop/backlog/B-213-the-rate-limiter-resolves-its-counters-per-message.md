---
status: open
round: 542
commit: d799f43d
paths: [packages/core/rpc_dart/lib/src/resilience/rate_limiter.dart]
probe: P-140
reason: "cost, not correctness, and the obvious fix is already known to break something: the per-message re-resolution exists so a live stream rebinds to the canonical counter after an eviction, so caching it needs the eviction case measured first"
---

# B-213 — the rate limiter resolves its counters once per message

Round 542's remainder, split out rather than left in a closed lead. Bench
`../probes/P-140-what-the-rate-limiter-admits.md`.

`_resolveSpecific` builds `'${call.serviceName}.${call.methodName}'`, runs `_keyExtractor`,
and — in dynamic mode — does an LRU touch (two map operations) on **every message of every
streaming call**, not once per call. Round 542 put `_tryAcquireAll` on the same path, so the
global counter's `tryAcquire` is there too.

## Why it is not a one-line cache

The re-resolution is deliberate and the code says why: `_cleanup` evicts an idle per-key
counter, a concurrent stream then recreates it, and a long-lived stream holding a captured
instance would meter against a counter nobody else shares — **doubling the effective limit**
for the pair. So a per-call cache has to answer what happens to a stream whose counter was
evicted mid-life.

## Why it matters

A firehose is exactly the shape that pays it: one bidi subscription with a large inbound rate
resolves its counters once per message, and the limiter's own cost scales with the load it
exists to shed.

## Witness a round would build

Nothing here is measured. P-140 counts admissions, not time, so the first thing this needs is
a throughput arm: messages per second through `_meterStream` with and without a key extractor,
against the same stream with no limiter at all. If the difference is not visible against
run-to-run spread, the lead closes as a non-cost.

Then, and only then, the eviction arm: a live stream, `cleanupInterval` short enough to evict
its counter, a second stream on the same key, and the question of whether the pair is bounded
by one counter or two.

## Also here, and smaller

**Nothing warns about a self-contradictory configuration.** A `perMethod` looser than `global`
was a hole before round 542 and is harmless after it, because the tighter counter binds either
way — but it is still a configuration whose author believed something the library does not do.
B-111 listed a construction-time warning as its option 2; it was not taken and is no longer
load-bearing. Cheap, non-breaking, and it needs a decision on how to compare a token bucket's
burst against a sliding window's rate.

## Owner decision

—
