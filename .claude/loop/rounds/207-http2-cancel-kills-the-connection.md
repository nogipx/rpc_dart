---
round: 207
verdict: DEFERRED
packages: [rpc_dart_http2]
lens: RPC-01
bench: P-02 — new
budget: probes 1/3, canaries 0/3
review: self — the session forbids the Agent tool unless the user asks, so the `loop.py review` prompt was answered in full against the record and the probe; approved 8 of 8 applicable (Q5 and Q6 are n/a: DEFERRED, so there is no fix to canary)
commit: no
---

# Round 207 — cancelling a stalled http2 call kills the connection for good

## Target

RPC-01 again, as `next` named it: the lens is applied but not swept. Round 206
fixed the shape in core; `methods/tests.md` is explicit that "every place means
every LAYER, and a sweep of one layer reads as complete". The only OTHER
implementation of the same accounting is `RpcHttp2ResponderTransport` (the
websocket transports delegate to the core one, so 206 covers them).

## Hypothesis

On HTTP/2 the pool belongs to package:http2, and rpc_dart throttles an upload by
PAUSING its subscription — which, per the note in `upload_backpressure_test`, is
what closes the receive window. So bytes stall pending at connection level. If
nothing credits them when the stream is torn down, the connection pool is spent
for good, exactly as in 206.

## Before

```
One connection. A call is stalled until the pool is visibly held (the "rise":
a unary Ping must HANG), then the stalled call is ENDED two different ways.

UPLOAD (bidi into a deaf handler)          ping before  stalled  ping@stall  ping after
  control: handler drains it                  pong      68 KiB     HUNG        pong
  case:    client cancels it                  pong      68 KiB     HUNG        HUNG

DOWNLOAD (server-stream, consumer pauses)  ping before  taken    ping@stall  ping after
  control: consumer resumes                   pong      324 msg    HUNG        pong
  case:    consumer cancels                   pong      372 msg    HUNG        HUNG

"ping after" polls for up to 20 s. 68 KiB is the HTTP/2 default connection
window (65535 + framing) -- no rpc_dart limit has that value.
```

Probe:
`packages/transport/rpc_dart_http2/.dart_tool/probe/aborted_upload_pool.dart`
(P-02). Bytes on the wire come from a raw TCP relay, per the rule that this
package's own upload test paid for: measure the wire, not the sender.

**Ablation.** Switching rpc_dart's own throttle off in place (`_fcOnDelivered`'s
pause and the `getMessagesForStream` onPause/onResume hop):

```
  upload control : 14286 KiB on the wire, ping during stall  pong, after  pong
  upload case    : 15291 KiB on the wire, ping during stall  pong, after  pong
```

Nothing hangs, and nothing dies — because nothing is ever pending. That is the
round-118 defect restored (13.8 MiB uploads), so it is not an option; it is what
identifies the enabling condition.

## Mechanism

`connection_queues._tryDispatch` credits the CONNECTION window only for messages
it moves into a stream's queue, and it will not move them while that stream's
consumer is paused. rpc_dart pauses precisely to throttle. So a stalled call
parks up to a whole connection window in `_stream2pendingMessages`.

When the stream is then reset, `stream_handler._closeStreamAbnormally` calls
`incomingQueue.removeStreamMessageQueue(id)`, which drops those pending messages
with no `dataProcessed` — so no WINDOW_UPDATE is ever emitted for bytes the peer
was charged for. RFC 9113 6.9.1 requires a receiver to account for
flow-controlled bytes at the connection level even when the stream is reset.

Draining instead of cancelling avoids it because the messages then move through
the stream queue normally, which is what credits them.

## After

n/a — not fixed.

## Canary

n/a — no fix. The control is what carries the claim: same rig, same stall, same
"rise", and only the ENDING differs.

## Gate

No code changed — the ablation was reverted in place and `git diff` is empty, so
the tree is byte-identical to HEAD, whose gate was green at the end of round 206.
`melos run analyze` re-run green for the loop-data commit.

## Not fixed

The discard is inside package:http2, and every lever rpc_dart has trades away a
bound this loop installed:

1. **Upstream.** `removeStreamMessageQueue` must credit the connection window for
   what it discards. Correct, and not ours to make. Worth reporting.
2. **Stop pausing; fail the call instead.** Always read (so the connection window
   keeps flowing), count per stream, and fail a stalled stream with
   RESOURCE_EXHAUSTED past its window. Bounds memory without holding the pool,
   but changes visible behaviour: a slow handler kills its own call instead of
   being throttled.
3. **A bigger connection window does NOT help** — the amount parked pending is
   itself bounded by the window, so enlarging it enlarges the leak in step. The
   measurement says so directly: 68 KiB on the wire, one cancel, dead.

Option 2 is a safety-for-safety trade, and `config.md` puts that with the owner
("Ask before trading speed for anything else"; this is the same shape). Filed as
B-12 with the numbers so the decision can be made on evidence rather than
re-derived.

## Links

Lens `../lenses/RPC-01-flow-control-credit-on-skip.md` — `applied: [206, 207]`,
paths widened to the transport packages, third instance recorded.
Bench `../probes/P-02-http2-aborted-call-pool.md` — new, validated by its control.
Lead `../backlog/B-12-http2-cancel-kills-the-connection.md` — new, awaiting owner.
Lesson `../lessons/L-02-vary-the-event-not-the-setup.md` — new.
Round `206-connection-credit-never-repaid.md` — the same shape one layer up.
