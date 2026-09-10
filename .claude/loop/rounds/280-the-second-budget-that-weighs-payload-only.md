---
round: 280
verdict: FIXED
packages: [rpc_dart]
lens: RPC-17
bench: P-30 — new
commit: yes
---

# Round 280 — the second budget that weighs payload only

## Target

Round 279's own generalisation, applied immediately rather than filed. Its lens
note says a dimension fixed is not a dimension closed, so the question it leaves
is: **which OTHER accounting weighs a message?** A grep for every weighing site
answers it in two families.

Nine `sizeOf:` sites, all `m.bufferedBytes` — so 279 fixed every queue in the
repository at once. And a second family that 279 did not touch:
`payload?.length ?? 0`, at the pre-method budget and at every flow-control
charge. This round takes the first of those.

## Hypothesis

`bufferPreMethod` parks a frame whose method is not yet resolved and charges
`message.payload?.length ?? 0` against a per-connection ceiling of
`maxMessageLengthBytes`. Metadata weighs ZERO there — which is the state round
245 found the queue's bound in, one budget over, never re-checked.

And it should be worse than the queue's, because the queue has a 4096-EVENT
ceiling behind its byte bound while `_preMethodBufferedMessages` is a plain
`List` with no count cap. If the bytes read as ~0, nothing else is counting.

## Before

4000 frames, each one payload byte plus 2000 tiny headers, through the
pipeline's admission check transcribed.

```
arm       charge  parked  refused   charged      RSS   ceiling
metadata  old       4000        0  0.00 MiB   789.2 MiB   16.0
payload   fixed     4000        0  15.63 MiB   11.7 MiB   16.0
```

Probe: `packages/core/rpc_dart/.dart_tool/probe/pre_method_weighs_payload_only.dart`

**789.2 MiB retained against a 16 MiB budget that read 0.00 MiB.** Nothing was
refused, because nothing was charged. The payload arm is what makes that a
verdict: the same budget, right at its ceiling, charging 15.63 MiB for 11.6 MiB
resident. Honest for the case it was written for, absent for the case a peer
picks.

## Mechanism

The budget exists for a frame-REORDER window — a DATA frame observed before its
metadata frame — so it was written thinking about payloads, and its own doc
comment says "Payload bytes parked...". A frame carrying one payload byte and a
header block takes the same path and costs it one byte.

## After

Both sites now charge `message.bufferedBytes`, which since round 279 includes
metadata and a per-entry charge. They must stay identical or the release path
desyncs from the connection-wide total, and both comments say so.

```
metadata  fixed      106     3894  15.93 MiB   27.6 MiB   16.0
payload   fixed     4000        0  15.63 MiB   11.7 MiB   16.0
```

789.2 -> 27.6 MiB; 4000 parked -> 106, with 3894 refused. The payload arm does
not move.

## Canary

`test/endpoint/pre_method_budget_weighs_metadata_test.dart` — with the charge
reverted the witness failed with

    Expected: a value greater than <64000>
      Actual: <1>
    the header block a parked frame retains must be charged

One byte, for a frame holding 2000 headers. Both GUARDs passed: a payload-only
frame is still charged exactly its payload, and taking the buffer still clears
the charge — which matters because the release path reads that number, and a
desync would leave the connection-wide total climbing until legitimate calls
were refused.

**One of the four tests is a weak witness and should be read as such**: "the
ceiling therefore stops a metadata flood" computes its own charge from
`bufferedBytes` rather than reading the state, so it passes under the ablation.
It documents the consequence; the first test is what pins the defect.

## Gate

`melos run analyze` (21 packages + wasm), `melos run test:unit --no-select`,
`melos run format:check`, `melos run license:check` — all green.

## Not fixed

**The other half of the second family: flow control.** `_fcOweConnection`,
`_fcDischarge` and `_fcOnDelivered` all charge `payload?.length ?? 0`, at six
sites across `channel_transport.dart` and both http2 transports. If credit is
returned by payload length while the wire carried a metadata-heavy frame, a peer
spends less window than it consumes — which is a backpressure bypass rather than
a memory bound, so it needs a different observable and its own round. Not filed
as a lead with no probe design; named here with its six line numbers, which is
what the next round needs.

## Links

RPC-17 (`applied:` gains 280) — fourth application, and the first to come from
asking the lens's own generalisation rather than from a new sweep. Bench P-30.
Round 279 is what pointed here.
