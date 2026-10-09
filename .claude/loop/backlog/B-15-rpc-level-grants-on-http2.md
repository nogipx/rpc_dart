---
status: closed (round 214)
round: 213
commit: 7c7c5109
paths: [packages/transport/rpc_dart_http2/lib/**]
probe: packages/transport/rpc_dart_http2/.dart_tool/probe/slow_consumer_is_throttled.dart
reason: owner decision — the benefit did not justify porting core's flow control onto two transports
---

# B-15 — cooperative backpressure on http2, via rpc-level grants

Proposed in round 212 as the alternative to reverting round 208, sized in round
213, and closed in round 214 without being built.

What it would have done: stop borrowing HTTP/2's window as the backpressure
signal and carry it at the rpc level instead — the responder emitting
`x-window-update` grants as it consumes, the caller parking on that credit, the
transport never ceasing to read, so a slow consumer is throttled rather than
failed. `RpcChannelTransport` already works this way; the cost was porting it
onto both http2 transports and removing the round-208 refusal only once the
replacement was measured.

Why it was raised at all, measured in round 213 (3000 x 4 KiB, 4 MiB window):

    fast handler            : completed, consumed 3000 of 3000, 15.4 s
    slow handler, 2 ms each : FAILED RpcStatusException(8), 2.1 s, consumed 67
    deaf handler            : FAILED, same status, 1.8 s, consumed 0

The behaviour that stands as a result is recorded as ACCEPTED, with those
numbers and the reasoning, in
`../checked/C-19-http2-refuses-a-slow-consumer.md`. Read that before touching
this area, and do not re-open this lead on the strength of the measurement
alone — the measurement was never in dispute, the trade-off was.

## Owner decision

**Closed (round 214).** The benefit did not justify the cost. The refusal from
round 208 stands, and `flowControlWindowBytes` is the knob for how much backlog
a call may build before it is failed.
