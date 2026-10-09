---
round: 496
verdict: FIXED
packages: [rpc_dart]
lens: RPC-25
bench: P-134 — new
commit: yes
severity: S2
---

# Round 496 — the sibling had solved it one layer up

## Target

B-105, twelfth in the audit's rank: the first pure-performance lead of this
intake, and the first in core.

Lens RPC-25 — the same abstraction more than once, read as a DUTY. The duty here
is "accumulate bytes until a length is known", and the library does it twice:
`RpcFrameMultiplexedChannel` for channel frames, `RpcMessageParser` for gRPC
messages. One had been made amortized and the other had not.

## Hypothesis

While a body is incomplete every chunk reallocates and copies the whole
unconsumed tail, so reassembly is O(N^2/C). Refuted if the cost per byte turned
out flat, or if some layer above reassembled first on every transport that
matters.

## Before

```
                      time      per KiB
 1 MiB in 65 chunks      7 ms   6.84 us
 2 MiB in 129 chunks    34 ms  16.60 us
 4 MiB in 257 chunks   122 ms  29.79 us
 8 MiB in 513 chunks   350 ms  42.72 us
16 MiB in 1025 chunks 1515 ms  92.47 us
```

Probe: `packages/core/rpc_dart/.dart_tool/probe/b105_parser_quadratic.dart`

Cost per byte rises 13.5x across a 16x rise in size, at a FIXED 16 KiB chunk —
which is the quadratic signature and what a single timing could not have shown.
A 16 MiB message took a second and a half to reassemble.

## Mechanism

`addBytes` allocated `unconsumed + data.length` and copied the tail every time.
While one body is incomplete `unconsumed` grows to the whole message, so 1024
chunks of a 16 MiB message copy up to 16 MiB each.

`compact()` then did `_bytes.sublist(readOffset)` — another full copy per parser
invocation.

## After

```
 1 MiB    0 ms  0.00 us/KiB
 2 MiB    1 ms  0.49 us/KiB
 4 MiB    2 ms  0.49 us/KiB
 8 MiB    3 ms  0.37 us/KiB
16 MiB    8 ms  0.49 us/KiB
```

Flat. 16 MiB: **1515 ms -> 8 ms**.

A capacity buffer with a separate valid length, grown geometrically —
**the same shape, and the same two method names, `RpcFrameMultiplexedChannel`
already used one layer up**. `compact()` now MOVES the tail down instead of
reallocating, so the common case (everything consumed) is free.

**And its other rule came with it, which is the part I would have missed.** That
channel's comment says the buffered-bytes limit is *"checked BEFORE the append,
which is the whole point"* — because with geometric growth, appending first lets
a peer past the bound make us allocate up to twice it before the bound is
consulted. The parser checked after. Moved.

## Canary

Exact-fit growth restored in `_ensureCapacity` — the WITNESS fails with
`Expected: a value less than <24> / Actual: <37.496993051906344>`, "8x the bytes
took 37.5x the time ... (small=34254us large=1284422us)". All three GUARDs stay
green.

The witness asserts a RATIO, not a duration: a wall-clock threshold is a flake on
a loaded machine, and what separates linear from quadratic is that doubling the
message does not double the cost per byte.

Three guards, because a buffer rewrite is exactly the change that breaks
correctness quietly: the buffered-bytes limit still fires; whole and split
messages still round-trip in order when fed in 7-byte pieces so every boundary
falls mid-header and mid-body; and 2000 whole messages against a 128 KiB bound
still pass, which is what says `compact()` still reclaims.

## Gate

`melos run analyze` SUCCESS over 21 packages plus rpc_dart_wasm;
`melos run test:unit --no-select` SUCCESS; `melos run test:web` SUCCESS (run
because this is core and the change is byte-buffer arithmetic — dart2js is a
separate runtime for exactly this kind of code); `melos run format:check` SUCCESS;
`melos run license:check` compliant.

## Not fixed

**The http2 end-to-end number the lead asks for second.** The parser is fed
identically by that path and the cost is inside it, so the measurement would add
transport noise to a settled question — but it is not measured, and no claim about
http2 throughput can cite this round.

**Allocation peak is unmeasured**, only time. Moving the limit check before the
append is what bounds allocation; the peak itself was not sampled.

**The header is still read through a 5-byte `sublist`** — one small copy per
message, which the sketch also names. `ByteData.sublistView` would avoid it. Left
alone: it is O(1) per message, invisible beside what was fixed, and every byte of
this file's arithmetic is now load-bearing for correctness, so a second change
wants its own witness.

**The stale comment the sketch names is gone** — `"reuse incoming data directly"`
described a branch that copied.

## Links

Lens RPC-25. Bench P-134 (new). Lead B-105 (closed).
`RpcFrameMultiplexedChannel._ensureCapacity` is the sibling this copied, and the
source of the pre-append rule.
