---
status: open
round: 206
commit: c48a14d8
paths: [packages/core/rpc_dart/lib/src/endpoint/**, packages/core/rpc_dart/lib/src/rpc/streams/**]
probe: packages/core/rpc_dart/.dart_tool/probe/conn_window_cancel.dart
reason: bench — three shapes could not produce a valid number; the gap is made of latency and an in-memory pair zeroes it out
---

# B-11 — does an endpoint client reach the connection-pool wedge?

Round 206 fixed the accounting at the transport (P-01, with a control). What it
could NOT measure is whether an ordinary `RpcCallerEndpoint` client reaches the
same wedge — a consumer that pauses a server-stream and then gives up on it,
which is the everyday form of "bytes buffered and never taken".

## What was tried

Three benches, all in `.dart_tool/probe/conn_window_cancel.dart`, none valid:

- **A unary call after 6 pause-then-cancel streams.** Reported `ok (pong)`. Too
  few bytes: a unary response fits in whatever credit is left, so it cannot see
  a partly drained pool.
- **Producer overrun after a pause.** Reported 0 — and 0 BEFORE any cancels
  too, which is the tell. One saturated stream is already parked on its window
  at the moment of the pause, so the handler has nothing left to run ahead
  with and the counter can never move.
- **30 pause-then-cancel streams against a 512 KiB pool**, then a fresh call.
  `ok (4 messages)`. If each cancel leaked anything at all, 30 rounds would have
  emptied the pool six times over.

## Why it probably did not reproduce

The gap is made of LATENCY, not volume. What leaks is whatever sits in the
transport's per-stream buffer at the instant of the cancel, and on a zero-latency
in-memory pair the consumer keeps up with the producer, so almost nothing is
outstanding. The demand chain is genuinely in place (`base_processor`
`_setupResponseHandler` pauses the transport subscription), so frames DO stay
undecoded in the transport's controller while paused — the amount is just small.

## What would settle it

A bench with real one-way latency, the way the 20 ms link settled the initial
send window (156.25 MiB against 4.05 MiB). Over websocket rather than a memory
pair, or an artificial delay in the paired byte channel. Then: N pause-cancel
streams, and read the pool through what a fresh stream can push before it
parks.

Not urgent — the transport-level defect it would extend is already fixed — but
until it is measured, "an endpoint client cannot hit this" is a guess.

## Blocker re-checked, round 247

Confirmed, not dissolved. Six `implements IRpcChannel` doubles exist in core's
tests and NONE of them delays anything; there is no latency helper in `lib/` or
`test/` at all. So the fourth attempt still has to build the link before it can
build the bench.

The cost is now concrete rather than a guess: a delayed paired channel is about
twenty-five lines with `_ManualChannel`
(`test/transports/receive_path_hardening_test.dart`) as the model — it already
controls delivery frame by frame, and what is missing is a `Future.delayed` on
the send side. The endpoint-level drive on top is what round 206 described.

Round 247 did not attempt it. Three shapes tried, none valid, a fourth
identified and not yet built.

## Owner decision

—
