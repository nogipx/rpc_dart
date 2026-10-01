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

### The `_halfClosedLocal` sweep (round 563, no fix applied)

**Three sites add to the set, and only ONE can leak** — the breadth question answered so the next round
does not re-derive it:

| site | shape | verdict |
| --- | --- | --- |
| `:908` | `_activeStreams[streamId] = stream;` then the add, no await between | safe |
| `:1059` `finishSending` | `endStreamNow()` and `sendData()` are both synchronous | safe |
| `:1021` `sendMessage` | `await pump.add(...)` THEN the add | **the only one** |

**Round 558 already narrowed it.** `add` now throws when the pump was disposed, so the teardown path no
longer reaches that line at all. What remains reachable is a release that lands during a SUCCESSFUL
send — a peer reset, for instance, where `:1221` clears every per-stream entry while the pump is fine
and the `add` completes normally. One leaked entry per such stream, and nothing removes it again.

The guard is `_activeStreams.containsKey(streamId)` on the re-add, which is the same identity question
round 541 used in core (`_cleanupStream(only:)`).

**NOT APPLIED, deliberately.** A one-line guard with no failing witness is not a proven fix, and the
witness needs a release driven into the window of a successful send — a rig this round did not have room
to build. Recorded so the next round starts from the sweep rather than the lead's prose.

### Round 564 — the map was invisible, and the easy shapes do not fill it

`../rounds/564-the-unreported-map-and-a-vacuous-zero.md`.

**`_halfClosedLocal` was the one per-stream map `health()` did not report**, while every sibling is
reported precisely because growth in one is the symptom of an entry added and never removed. Now
exposed as `halfClosedLocal`, so the leak class has an observable at all.

**And two canaries both PASSED, which is what this round established.** Dropping the removal from
`releaseStreamId`, and then from the inline release as well, changed nothing — so unary and
server-stream **never populate the map**: neither reaches `sendMessage(endStream: true)` nor
`finishSending` on this transport. A guard asserting `halfClosedLocal == 0` for those shapes is a
vacuous zero, and without the second canary it would have shipped as coverage.

**So the rig the fix still needs is now named**: a client-stream or bidi upload, which does reach those
sites, with a release driven into the window while the send is parked. `P-183` already parks a pump at
the pump level and is half of it.

### Still open: the `_halfClosedLocal` leak

`sendMessage` re-adds the stream id AFTER its await, so a cleanup that ran in between leaves one entry
per stream behind. A leak rather than a truncation, in the caller transport's bookkeeping rather than
the pump's, and it needs its own rig — the pump probe cannot see it.

Also named by this lead and unmeasured: `_waiters` can be overtaken by a NEW `add`. A different shape
from the half-close race, and ordering between two concurrent sends on one stream is the caller's to
serialise today.

## Owner decision

—
