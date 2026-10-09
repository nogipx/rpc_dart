---
file: packages/transport/rpc_dart_websocket/test/first_frame_park_over_socket_test.dart
round: 366
commit: b17af71c
paths: [packages/core/rpc_dart/lib/src/rpc/transports/channel_transport.dart, packages/core/rpc_dart/lib/src/core/security_policy.dart, packages/transport/rpc_dart_websocket/lib/**]
status: valid
---

# P-58 — does a sender park over a real socket?

## Why it exists

`initialSendWindowBytes` (64 KiB) arrived in 6.0.0; 5.0.1 had no such parameter.
A downstream consumer chunks blobs at 256 KiB a frame and its uploads began
failing on exactly the release that carried the bump. The question is whether
the shipped policy puts a sender into the parked state at all — and the answer
depends entirely on the harness.

## The harness, and why the obvious one lies

`RpcChannelTransport.pair()` answers **never**: the peer's grant is already there
by the time the next send asks, so nothing waits, even with the handler asleep
eight seconds. Every flow-control question answered against the in-process pair
is answered about a system nobody runs.

So: a genuine WebSocket, and a dumb TCP relay in the middle that holds every
chunk for a fixed delay in both directions. Latency alone is the variable, no
Docker, no bandwidth ceiling. Peak `flowControlStateSizes['waiters']` is sampled
every 20 ms.

## The numbers (round 366)

256 KiB frames, handler 150 ms per frame:

```
frames   6.0.0 defaults   5.0.1 shape (no initial window)
1        no park          no park
2        parks ~1xRTT     never
3        parks ~1xRTT     never
8        parks ~1xRTT     never
```

Park duration tracks RTT exactly — 20 ms at 0, 40 ms at 40, 200 ms at 200 — so
it is the wait for the peer's FIRST grant, not congestion.

## Measures

Peak `RpcChannelTransport.flowControlStateSizes['waiters']`, sampled every 20 ms
for the life of the call, and the wall-clock duration of each park. Taken on the
SENDER, which is the side that owns the credit; the receiver's arrival count is
read too, to establish that a park loses nothing.

## Control

The 5.0.1 column is the control: the same harness with
`initialSendWindowBytes: null`, which is the shape that shipped before 6.0.0.
It reads `never` in every row where the 6.0.0 column parks, so the bench
distinguishes the mechanism under test from the rest of the flow-control stack.

The second control is the harness itself. `RpcChannelTransport.pair()` answers
`never park` in EVERY row, including the ones a real socket parks in — an
in-process pair has the peer's grant ready before the next send asks. A bench
built on it cannot see this defect at all, which is why the relay exists.

## What it establishes, and what it does not

Establishes: the parked state is reachable on the shipping path over any link
with a round trip, and is NOT reachable on the 5.0.1 shape. That is the version
delta, measured rather than argued.

Does not establish: that parking alone loses anything. It does not — all frames
arrive in every row above. Parking is the PRECONDITION for the defect round 366
fixed, not the defect.

## Corrected by round 445 — which park this is about

The line above, *"`RpcChannelTransport.pair()` answers never park in EVERY
row"*, is true and is about the LATENCY-shaped park: the wait for the peer's
first grant, which an in-process pair has ready before the next send asks.

**It is not true of a park made of VOLUME.** Drive credit negative by
arithmetic — a 600-byte frame into a 512-byte window — and the pair parks
reliably, with no socket and no RTT. P-99 measures frame ORDER around such a
park and needs no relay at all.

Read as the stronger claim "a pair cannot measure parking", this note would have
cost round 445 its instrument. Ask which of the two shapes a question is about
before reaching for the relay.

## Trap worth keeping

The credit gate admits on `credit > 0`, not on whether the message FITS. A
256 KiB frame therefore passes a 64 KiB window and drives the balance negative,
so the FIRST frame never parks and the second one always does. A reading of the
constants alone predicts the opposite, and did.

## Reading

rpc_dart + rpc_dart_websocket — does a sender actually park on the
flow-control window, over a real WebSocket through a TCP relay that delays
every chunk by a fixed amount in both directions. **Exists because the obvious
harness lies**: `RpcChannelTransport.pair()` reports "never parks" in every
row, including the ones a real socket parks in, so every flow-control question
answered against the in-process pair is answered about a system nobody runs.
Its control is the 5.0.1 shape (`initialSendWindowBytes: null`), which never
parks where 6.0.0 does. Park duration tracks RTT exactly — 20/40/200 ms — so
it measures the wait for the peer's first grant rather than congestion.
Reports peak `flowControlStateSizes['waiters']` per policy, which is what B-47
needs to be decided
