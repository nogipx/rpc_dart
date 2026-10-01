---
status: closed (round 565)
round: 565
commit: 4acd6833
paths: [packages/transport/rpc_dart_http2/lib/src/transports/http2/rpc_http2_caller_transport.dart, packages/transport/rpc_dart_http2/lib/src/transports/http2/rpc_http2_common.dart]
probe: P-187
reason: "bench — all three filed claims are now measured and fixed: the two pump ones in round 558 (P-183), the `_halfClosedLocal` leak in round 565 (P-187). What the measuring turned up and did not fix is B-221; the `_waiters` ordering item was never part of the three and is noted there"
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

> **REFUTED by round 565, and left standing above as the claim that was acted on.** Both paragraphs
> are false. The same ablation makes round 564's own test read **10**, and `unary/caller.dart:559-563`
> passes `endStream: true` to `sendMessage`, so unary fills the map on every call. The rig named in the
> second paragraph was not needed; what was needed was a window the rig owns.

### Round 565 — the leak CONFIRMED and FIXED, and round 564's claim refuted

`../rounds/565-the-canary-that-reported-a-pass.md`. Bench `P-187`.

```
WITNESS  reset while the endStream send is parked   halfClosedLocal 1 -> 0
CONTROL  window opens first, send completes         halfClosedLocal 1 (unchanged)
REACH    a later releaseStreamId                    1 -> 0
STACK    the same race via RpcCallerEndpoint        0 before and after
```

**The rig round 564 asked for was not needed, and its central claim is false.** Re-running the
ablation round 564 describes — both `_halfClosedLocal` removals dropped — makes its own test read
**10**, one per call, not pass: the unary caller passes `endStream: true` to `sendMessage`
(`unary/caller.dart:559-563`), so the add site is reached on every unary call. Why its canaries
reported passes cannot be recovered from the record; nothing changed those lines in between.

**Fixed** with `_activeStreams.containsKey(streamId)` on the re-add, the guard rounds 563 and 564
both declined for want of a witness. The witness exists because the WINDOW is owned by the rig:
hand-rolled SETTINGS with `INITIAL_WINDOW_SIZE=64`, which a real server cannot be made to do on cue.

**Severity, measured rather than assumed**: not reachable through `RpcCallerEndpoint`, because the
pipeline releases the id when the call ends and that removes the entry. The exposure is a direct user
of the transport — public API, and the `IRpcTransport` contract it implements.

**`_waiters` overtaken by a NEW `add` was never one of the three claims** and is still unmeasured. It
moves to `B-221` as its third item rather than closing with this lead, since a closed lead's remainder
is routed to by nothing.

## Owner decision

—
