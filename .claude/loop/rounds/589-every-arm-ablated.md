---
round: 589
verdict: FIXED
packages: [rpc_dart, rpc_dart_http]
lens: RPC-15
bench: P-208 — reused
budget: probes 0/5, canaries 3/5
commit: yes
release: none
---

# Round 589 — every arm ablated

## Target

`B-224`'s remaining two members, and the question the owner actually asked: do these
tests catch regressions. Round 588 fixed three arms and ablated only one of them.

Lens RPC-15, on this round's immediate predecessor again.

## Hypothesis

The two members left cannot be fixed by waiting, because they measure a resource the
test does not own — the PROCESS's resident size, and scheduling latency. Each has an
invariant underneath the proxy, and reading the invariant makes them deterministic.

## Before

```
oversized_chunk_not_copied     Expected a value less than <16777216>, Actual <31653888>   at 32
the_drain_is_signalled         Expected a value less than <35>, Actual <92>              at 32
```

And a reading that only appeared once the first was rewritten: an idle-baseline
subtraction still read **34.7 MiB** at `--concurrency=32`, because the drift during the
feed is not the drift during the baseline window.

## Mechanism

**RSS is not attributable.** `dart test` runs suites as isolates inside one process, so
`ProcessInfo.currentRss` belongs to every suite at once. The invariant under it is
"the oversized chunk was never appended to the reassembly buffer".

**A latency ceiling is a statement about scheduling**, which contention falsifies by
definition. The invariant under it is "the drain ends when its own work does" — and
what distinguishes that from polling is that polling QUANTISES: two releases inside
one 50 ms tick produce the same drain duration.

## After

`RpcFrameMultiplexedChannel.peakReassemblyBytes`, a high-water mark. A PEAK and not a
current size because both readers reset it — a completed frame compacts the buffer and
`_failChannel` drops it outright.

The drain arm takes the DIFFERENCE between two drains releasing 28 ms apart, best of
three attempts: the signal is capped at ~48 ms by the tick itself, and polling cannot
produce the gap on any attempt, so taking the largest costs nothing.

**A sixth member was found by the gate: round 587's own test.** `an_orderly_close_is_
not_an_error_per_call` slept 300 ms to park 8 requests; under the gate one was still
in the client, failed with the transport OPEN, and was logged at `error` — correctly,
which read here as the defect. It now waits for the server to have received all of
them, and for the record count to settle.

```
concurrency sweep on the core suite, gate effective is ~16
  16   green
  24   green
  32   green
  48   green
```

## Canary

Three, one per arm this round changed:

```
oversized_chunk_not_copied        append before the cap check   peak 67108864 against 1048576    RED
the_drain_is_signalled            _runDrain polled at 50 ms     53/52, 52/52, 51/51 -> diff 0    RED
an_orderly_close_is_not_an_error  the _isClosed branch off      8 errors for 8 calls             RED
```

**The first is why the round exists.** Its first instrument read the buffer's CURRENT
size and the ablation PASSED — both readers reset it, so the replacement was as blind
as the RSS proxy. An instrument rewrite changes what a test can SEE, and nothing but
an ablation checks that.

## Re-verified, not this round's canaries

Round 588's other two rewrites, ablated here so all six members of the family are now
known to fail when their subject does:

```
the_window_counts_wire_bytes      window: null                  waiters 0                        RED
response_sink_stops_at_ending     the ending made a no-op       produced 37 more (6 -> 43)       RED
audit_frame_reassembly_linear     _ensureCapacity exact growth  ratio 4.15 (quadratic)           RED
```

Six for six, each with a message that names the regression rather than a number.

## Gate

```
melos run analyze                SUCCESS   21 packages + rpc_dart_wasm
melos run test:unit --no-select  SUCCESS   twice, rpc_dart +1877 ~1, rpc_dart_http +211
melos run format:check           SUCCESS   0 changed
melos run license:check          SUCCESS   2232 / 2232, REUSE compliant
```

## Not fixed

**One absolute wall-clock bound is left in the drain file**: `GUARD a drain with
nothing in flight returns promptly`, `lessThan(35)`. It has not failed at any
concurrency tried, and it does not discriminate polled from signalled anyway — with
nothing in flight both designs skip the wait — so it guards "does not wait when there
is nothing to wait for". Left alone rather than rewritten on speculation.

**`peakReassemblyBytes` is new public API**, one int getter on a class that already
exposes `isClosed`. Justified the same way `flowControlStateSizes` is public on the
channel transport, and useful outside a test: against a configured cap it says how
much of the reassembly budget a peer's framing really uses. Not behind
`@visibleForTesting`, because nothing in this repo uses that annotation.

**No frequency at the gate's own 16.** The sweep is one run per level; what the round
establishes is that six arms survive 3x the gate's oversubscription and that each
still fails when its subject breaks.

**No serial lane was needed**, so the gate's shape is untouched — which was the open
question B-224 left for the owner.

## Links

Lead `../backlog/B-224-the-wire-byte-window-test-flakes-under-the-gates-concurrency.md` — CLOSED.
Bench `../probes/P-208-how-much-margin-a-timing-assertion-has.md` — reused.
Round `588` — the cause, and the three arms fixed there.
