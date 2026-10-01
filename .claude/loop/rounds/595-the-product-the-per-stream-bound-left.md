---
round: 595
verdict: FIXED
packages: [rpc_dart]
lens: RPC-17
bench: P-211 — reused
budget: probes 0/5, canaries 2/5
commit: yes
release: changelog
---

# Round 595 — the product the per-stream bound left

## Target

B-138's remainder, which round 594 named: every per-stream ceiling multiplies by
the number of streams a peer opens. Taken because it is the open end of the
lead the previous round worked, and P-211 already measures it. The fix changes
public behaviour (a new refusal), so the ceiling was put to the owner before the
fix: **cap at `flowControlConnectionWindowBytes`**, chosen over a new policy knob
and over leaving it.

Scope, counted before the fix: every buffer that charges un-consumed request
bytes. Two counters hold them — the transport ledger (bidi, server-stream) and,
since round 594, the pipeline (client-stream sink, pre-bind lists). Both get the
cap.

## Hypothesis

The total held for parked handlers on one connection grows linearly with the
stream count. Refuted if 16 streams hold about what 8 do.

## Before

```
                                   streams   RETAINED
client-stream, peer ignores window    8      8184  (~128 MiB)
client-stream, peer ignores window   16     16368  (~256 MiB)
client-stream, honest peer            8      2056  (~32 MiB)
```

Probe: `packages/core/rpc_dart/.dart_tool/probe/b138_a_flood_into_a_stalled_handler.dart`
with arms `multi N`, `multihonest N`, `multibidi N` (2000 messages of 16 KiB per
stream, responder on defaults). At the default `maxActiveStreams` of 4096 the
line extrapolates to ~64 GiB.

## Mechanism

Both ceilings are per stream. Flow control would bound the total, but it is a
send-side protocol a foreign peer ignores, and the pool is repaid on the peer's
half-close while the bytes stay resident, so even an honest peer's residency is
not bounded by it.

## After

```
                                   streams   RETAINED          refusal
client-stream, peer ignores window    8      4093  (~64 MiB)   RESOURCE_EXHAUSTED
client-stream, peer ignores window   16      4093  (~64 MiB)   RESOURCE_EXHAUSTED
bidi, peer ignores window            16      4093  (~64 MiB)   RESOURCE_EXHAUSTED
client-stream, honest peer            8      2056  (~32 MiB)   none
```

- `RpcStreamBufferLedger` takes `limitTotalBytes`; the transport passes the
  connection window. Over it, the stream that crosses fails as for a per-stream
  overflow.
- A refused message's bytes now go back to the connection pool at once. Without
  that, a refusal left them owed and the sender wedged: the existing
  `flow_control_connection_debt_test` caught it on the first run (`sender wedged
  at call 8`), since its receiver binds views it never reads and the new total
  refuses the fifth.
- The pipeline's client-stream sinks and pre-bind lists share one
  `RpcResponderBufferBudget` (internal, hidden from the barrel), capped the same
  way and returned per stream at teardown, like the pre-method budget beside it.

## Canary

1. Pipeline connection cap off: `client-streams on one connection hold no more
   than its window` fails, `Expected: <= 128, Actual: <3992>`.
2. Transport total off: `bidi streams on one connection hold no more than its
   window` fails, `Actual: <3992>`. Each half fails only its own shape.
3. `releaseBuffered` off: `a unary torn down with frames still held returns them`
   fails, the next ordinary call refused with `RpcStatusException(8): Too much
   buffered before the responder took it (... 131072 per connection)`. The first
   version of that witness left the connection 8 messages short of full and
   passed under the canary; it now drives the unary past the total.
4. The refusal's credit off: `flow_control_connection_debt_test` fails, `sender
   wedged at call 8 after 2048 KiB`.

One switch found nothing and its change was REMOVED: releasing the ledger charge
when a per-stream controller is cancelled. A bidi handler that `break`s out of
`await for` with a burst behind it was the witness, and it passed with the
release off — the pipeline had already pulled the burst out of the transport's
controller. Teardown still releases it via `releaseStreamId`.

## Gate

`melos run analyze`, `melos run test:unit --no-select` (15 packages, rpc_dart
+1892, rpc_dart_websocket +242), `melos run format:check`, `melos run
license:check` — green. Both new test files pass on `-p node`.

## Not fixed

Filed as B-225:
- the two counters are separate, so a peer filling both shapes can hold twice the
  window;
- zero-copy payloads weigh 0 bytes and are bounded only per stream by count;
- the pause contract on `IRpcChannel`'s example, the isolate and wasm channels.

## Links

Lead `../backlog/B-138-the-websocket-channel-has-no-read-backpressure.md` — closed.
Lead `../backlog/B-225-what-the-connection-total-does-not-see.md` — new.
Bench `../probes/P-211-a-flood-into-a-stalled-handler.md` — reused, arms added.
Lens `../lenses/RPC-17-limit-fires-after-residency.md` — `applied: [595]`.
Test `packages/core/rpc_dart/test/transports/the_connection_total_is_bounded_test.dart`.
