---
round: 213 measured, 214 accepted
commit: 7c7c5109
paths: [packages/transport/rpc_dart_http2/lib/**]
scope: [http2]
---

# C-19 — http2 refuses a consumer that falls behind, by design

**Do not re-open this as a defect.** It is measured, understood, and accepted by
the owner.

On the http2 transports a call whose consumer falls more than
`flowControlWindowBytes` behind is failed with RESOURCE_EXHAUSTED. That is not
limited to a consumer which stops: since round 208 nothing throttles the
producer, so the un-consumed backlog grows at the RATE GAP and any positive gap
reaches the window given a large enough upload.

Measured in round 213, 3000 x 4 KiB uploaded against the default 4 MiB window:

    fast handler                : completed, consumed 3000 of 3000, 15.4 s
    slow handler, 2 ms each     : FAILED RpcStatusException(8), 2.1 s,
                                  consumed 67 of 3000
    deaf handler                : FAILED, same status, 1.8 s, consumed 0

Bench: `../probes/P-05-slow-consumer-is-throttled.md`.

## Control

The `fast` handler — the same rig with the rate gap removed. It completes and
consumes all 3000, so the failure of the other two arms is attributable to the
gap and not to the volume. Without it the numbers would say only "big uploads
fail", which is a different and much less useful claim.

## Why it is this way

Memory cannot be bounded without either throttling the producer or failing the
call. Throttling used to be implemented by not reading, and that is what made
package:http2's uncredited discard fatal — one cancelled stalled call killed the
connection permanently, in both directions (round 207, `../probes/P-02-http2-aborted-call-pool.md`).
Round 208 therefore chose to keep reading and fail the call.

The remaining way to throttle without ever not-reading is rpc-level
`x-window-update` grants, as `RpcChannelTransport` does. That was proposed,
sized, and **withdrawn by the owner** as not worth porting onto two transports:
`../backlog/B-15-rpc-level-grants-on-http2.md`.

## What would change this

Only a change of requirement, not a new measurement. If an application needs a
slow consumer throttled rather than failed, the knob is
`flowControlWindowBytes` — raising it buys proportionally more backlog before
the refusal, and does not remove it. A rate gap always wins eventually.

The upstream fix in package:http2 (`removeStreamMessageQueue` must credit the
connection window it discards, RFC 9113 6.9.1) would make pausing safe again and
reopen the cheap route. It is unreported as of round 214.
