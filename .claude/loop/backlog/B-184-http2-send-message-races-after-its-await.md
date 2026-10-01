---
status: open (round 558 fixed two of three; the `_halfClosedLocal` leak remains)
round: 558
commit: 8253fe8a
paths: [packages/transport/rpc_dart_http2/lib/src/transports/http2/rpc_http2_caller_transport.dart, packages/transport/rpc_dart_http2/lib/src/transports/http2/rpc_http2_common.dart]
probe: none — static read, nothing run
reason: "bench — filed from a static read (external audit, 2026-09-28, intake 8253fe8a); the auditing container had no Dart SDK, so nothing here was run and the witness below is unbuilt"
---

# B-184 — http2 caller: sendMessage and finishSending race a disposed or parked pump

**Filed from the external audit of 2026-09-28** (core + transports, read in full,
transport findings re-checked against the code). Confidence from reading:
**medium**. Nothing here was measured; the witness below is the first
thing a round owes this lead, and it may refute it.

If release/reset/reconnect disposes the pump while `add` is parked on the window, `add` returns silently and the send reads as success; the id is then re-added to `_halfClosedLocal` after cleanup (one leaked entry per stream); `finishSending` while a `sendMessage` is parked puts END_STREAM first, and the parked message is dropped — the request is truncated with no error.

## The shape

`packages/transport/rpc_dart_http2/lib/src/transports/http2/rpc_http2_caller_transport.dart:996-1000, 1034-1038`; `rpc_http2_common.dart:158-167`
(waiters can also be overtaken by a new `add`).

## Why it matters

Silent request truncation — the class of defect B-74 fixed in core.

## Witness a round would build

Client-stream with a closed peer window: `send(x)` parked, `finishSending()`;
server's received count.

## Fix sketch

Make disposal fail parked adds; order END_STREAM behind parked data.

## Outcome (round 558) — two of three CONFIRMED and fixed

`../rounds/558-the-half-close-overtook-the-payload.md`. Bench
`../probes/P-183-what-reaches-the-wire-when-a-parked-send-meets-a-half-close.md`.

```
  CONTROL drains throughout            data 64B eos=false, data 0B eos=true
  parked send, then endStreamNow()     data 0B eos=true        <- payload GONE, add returned TRUE
  parked send, then dispose()          NOTHING                 <- add returned TRUE

after
  parked send, then endStreamNow()     data 64B eos=false, data 0B eos=true
  parked send, then dispose()          add throws status 14, naming the stream
```

**Silent request truncation confirmed**, exactly as filed. The CONTROL is what makes the middle row
a loss rather than a rig that never delivers payload.

Fixed as two separate mechanisms, each with its own canary: `endStreamNow` now lets parked payload go
first — it records the request, wakes the waiter, and the woken `add` emits the END_STREAM it owes, so
nothing waits on the peer and the controller buffers until the window opens — and `add` THROWS instead
of returning when it cannot deliver, because returning normally is how a dropped payload came to read
as a completed send.

### Still open: the `_halfClosedLocal` leak

`sendMessage` re-adds the stream id AFTER its await, so a cleanup that ran in between leaves one entry
per stream behind. A leak rather than a truncation, in the caller transport's bookkeeping rather than
the pump's, and it needs its own rig — the pump probe cannot see it.

Also named by this lead and unmeasured: `_waiters` can be overtaken by a NEW `add`. A different shape
from the half-close race, and ordering between two concurrent sends on one stream is the caller's to
serialise today.

## Owner decision

—
