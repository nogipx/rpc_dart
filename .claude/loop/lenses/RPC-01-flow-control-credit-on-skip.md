---
refines: U-07
paths: [packages/core/rpc_dart/lib/**, packages/transport/*/lib/**]
applies: there is credit accounting released on message delivery
breaks: a wedged connection — a hang.
applied: [206, 207, 208, 212]
status: confirmed (round 212)
---

# RPC-01 — Flow-control credit on the skip path

## Shape

A frame is refused or skipped without becoming a message, while the credit
return hangs on the "message delivered" event.

Round 206 widened this: the frame does not have to be SKIPPED. It is enough that
it is delivered to a consumer that never takes it, because the credit return
hangs on the same event either way. And where there are two levels of
accounting, ask the question once per level — a reclaim at one is not a reclaim
at the other.

## Detector

`_fcOnConsumed` and every one of its callers; every place a frame is dropped
before it becomes a message; `sendMessage` as the sole consumer of credit. Then,
per level: what reclaims credit at teardown, and is the RETURN path gated on a
flag that belongs to the other level?

## Ask

Will the credit the sender has already charged itself ever come back?

## Evidence

An 8 MiB window with 2 MiB per refusal: it wedged on exactly the fourth refusal.
Metadata frames are outside flow control — checked, not assumed (round 162,
off-journal).

Round 206, same detector over the CONNECTION pool, which did not exist in 162.
A 1 MiB pool, a 256 KiB stream window, 256 KiB per call, 12 sequential streams:

    receiver drains the per-stream view    12 calls, 3072 KiB, never wedged
    receiver binds it and never reads       4 calls, 1024 KiB, then dead
    receiver drains, per-stream window OFF  4 calls, 1024 KiB, then dead

1024 KiB is exactly the pool. `_fcForget` reclaimed the per-stream window at
teardown and nothing reclaimed the shared one; and every gate tested
`flowControlWindowBytes` alone, so a pool-only policy metered nothing while
still charging each send. Both fixed; bench `../probes/P-01-connection-window-debt.md`.

Round 207, the same detector one LAYER down — the paths above were widened to
the transports for it. On http2 the pool belongs to package:http2, and rpc_dart
throttles by pausing its subscription, which parks up to a whole connection
window as pending. Ending the stalled call by cancelling drops it uncredited:

    upload,   ended by draining -> the connection recovers
    upload,   ended by cancel   -> every later call HUNG, polled 20 s
    download, ended by resuming -> the connection recovers
    download, ended by cancel   -> every later call HUNG

One cancel is enough (68 KiB, the HTTP/2 default window). Round 208 fixed it by
the owner's choice: never stop reading, keep `flowControlWindowBytes` as the
budget, and FAIL a call past it. All four runs recover, and the bound still
bites at 4171 KiB against 15291 KiB with no bound at all. Bench
`../probes/P-02-http2-aborted-call-pool.md`; lead
`../backlog/B-12-http2-cancel-kills-the-connection.md`.

The lesson that generalises past http2: **a bound implemented by NOT READING is
a bound held in the layer below**, and whatever that layer does with it on
teardown is not yours to control. Prefer a bound you can account for yourself.

The transport packages other than http2 delegate to the core transport, so 206
covers them: `RpcChannelTransport` is the only `IRpcFlowControlled` under
websocket and isolate.

Round 212, the same lens pointed at bookkeeping rather than bytes. Credit state
can outlive the stream it belongs to: `_fcForget` clears the entry at teardown
and a LATE peer grant for that id writes it straight back, where nothing removes
it again. One entry per abandoned upload, linear, zero for drained traffic.
Capped, so not unbounded — the cost is that once the cap fills with dead ids no
new stream is seeded and `initialSendWindowBytes` stops applying.

> **Ask the question of the BOOKKEEPING as well as of the bytes.** "Does the
> credit come back?" has a twin: "does the record of it go away?" Both hops
> here — the grant and the forget — had to be instrumented before the order was
> visible, and the first theory was wrong.
