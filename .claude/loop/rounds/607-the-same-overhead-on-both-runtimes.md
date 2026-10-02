---
round: 607
verdict: CLEAN
packages: [rpc_dart_compression]
lens: RPC-07
bench: none — the observable is the request DATA frame size, read off the channel by the test on both targets
budget: probes 0/5, canaries 0/5
commit: yes
release: none
---

# Round 607 — the same overhead on both runtimes

## Target

B-214: round 543 made core's compare-and-keep-smaller test VM-only (core registers no
codec on dart2js), which left the property unmeasured against `RpcGzipCodec`, the
cross-platform codec in `rpc_dart_compression`. The lead names where the arm belongs
and what outcome would be interesting: a DISAGREEMENT between the two runtimes.

## Hypothesis

With `RpcGzipCodec` registered, enabling compression never makes a small
incompressible message bigger, on the VM and on node alike.

## Before

```
                                VM                 node
                            off    on          off    on
32 B incompressible          42    42           42    42
64 B incompressible          74    74           74    74
128 B incompressible        138   138          138   138
192 B incompressible        202   202          202   202
4096 B incompressible      4107  3138         4107  3149   (guard: still shrinks)
32 B compressible            42    33           42    33   (guard: still shrinks)
```

Test: `packages/core/rpc_dart_compression/test/compare_and_keep_smaller_test.dart`,
core's round-513 rig with `RpcGzipCodec.register()`, run `-p vm,node`.

## Control

`compressIfSmaller` in core forced to keep the compressed form: all four witnesses
fail on BOTH platforms with identical numbers — `62 / 94 / 155 / 206` against
`42 / 74 / 138 / 202`. So the bench sees an unconditional compressor, and the codec's
fixed overhead at these sizes is the same on both runtimes. The only difference is
the large guard (3138 against 3149), which never decides the flip.

## Mechanism

n/a — the property holds; `RpcGzipCodec` differs between runtimes only in its
compression ratio at size, not in the small-message overhead that decides it.

## After

n/a — no library change; the test is the new coverage.

## Canary

n/a — no fix. The control above is the ablation.

## Gate

`rpc_dart_compression` analyzed clean; its whole suite green on `-p vm,node` (59);
`melos run format:check` and `melos run license:check` green. `lib/` unchanged.

## Not fixed

Nothing in B-214.

## Links

Lead `../backlog/B-214-compare-and-keep-smaller-has-no-web-arm.md` — closed.
Lens `../lenses/RPC-07-web-as-separate-runtime.md` — `applied: [607]`.
