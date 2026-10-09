---
round: 645
verdict: FIXED
packages: [rpc_dart]
lens: RPC-17
bench: none — the witness test is the measurement; the coverage-review probe is cov_core_mux_oversized_second.dart
budget: probes 2/5, canaries 1/5
commit: yes
release: changelog
severity: S2
---

# Round 645 — an oversized frame mid-chunk

## Target

A coverage-review finding (round 640) in `RpcFrameMultiplexedChannel._onData`:
a client refuses an oversized frame by failing its call, but the check looked
only at the frame at the start of a chunk.

## Hypothesis

An oversized frame fails only its call wherever it sits in a chunk.

## Before

```
client multiplexer, 64 KiB ceiling, one chunk each
oversized frame first, small after          [3: status 8, 5: data 16]   open
small frame, then oversized frame           [error]                     closed
small frame + oversized header only         [error]                     closed
```

## Control

The first row.

## Mechanism

RPC-17, where a limit fires. `_refusedFrameHeader` reads the header at logical
offset 0. A frame behind one that fits got past it and into `decodeAll`,
which throws on its size, or into the buffer-overflow check -- both fail the
whole channel, and the frame before it is dropped too. A channel that
coalesces frames reaches it: raw TCP or a Unix socket, and a peer packing
several frames into one WebSocket message, which the wire format allows.
First-party senders do not coalesce.

## After

When offset 0 is not refused, the header chain is walked for a later refused
frame; the frames before it are decoded and emitted, and the loop steps over
it as before. Only the first frame can straddle the buffer, so the walk reads
the rest from the chunk, and a chunk holding one frame (the WebSocket case)
returns before allocating anything.

```
small frame, then oversized frame           [1: data 16, 3: status 8, 5: data 16]   open
small frame + oversized header only         [1: data 16, 3: status 8, 5: data 16]   open
frame split across chunks, then oversized   [1: data 100, 3: status 8, 5: data 16]  open
```

## Canary

The walk disabled: three of four witness cases read `[error]`.

## Gate

Rounds 641-645 together: `analyze` (21 packages and wasm) green, `format`
clean. `test:unit`: rpc_dart 2009 passed, every other package green except
one rpc_dart_websocket red, `a_refused_upgrade_has_a_deadline_test` (1 of 8
refusals read `closed` instead of 403). The rounds do not touch that path; the
package rerun alone is green (279), and the refusal alone reads `403: 800` over
100 rounds. Filed as B-241 with round 640's websocket red, the same shape.
`test:web` green, rpc_dart 1955 passed on node.

## Not fixed

Servers close on an oversized frame by design (`closeOnOversizedFrame`); not
touched.

## Links

Lens `../lenses/RPC-17-limit-fires-after-residency.md` — `applied: [..., 645]`.
Test `packages/core/rpc_dart/test/transports/an_oversized_frame_mid_chunk_fails_only_its_call_test.dart`.
