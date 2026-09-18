---
round: 388
verdict: FIXED
packages: [rpc_dart_http2]
lens: RPC-25
bench: P-78 — reused
commit: yes
---

# Round 388 — the reset the dependency already sends

## Target

B-53, at the owner's direction. Round 387 proved the trigger by ablation and
put four routes to the owner; they chose **delay the reset by a grace**, on the
reasoning that a finishing call ends inside the grace while an abandoned
download does not.

Reading `package:http2` to implement that found something better, and the round
shipped that instead — stated here because it is a deviation from what was
asked, and the owner should see it as one.

## Hypothesis

A grace before `stream.terminate()` lets an in-flight trailer land, so a
finishing call sends no reset while an abandoned download still does.

## Before

P-78 reused unchanged:

```
link     consumer lets go at   result
direct   the last payload      5 of 5 clean
direct   onDone (the trailer)  5 of 5 clean
50 ms    the last payload      DEAD from call 2   <- the SERVER closed
50 ms    onDone (the trailer)  5 of 5 clean
```

## Mechanism

**`package:http2` already sends the reset itself, and rpc_dart was sending a
second one.** `stream_handler.dart:332`:

```dart
streamQueueIn.onCancel.then((_) {
  if (stream.state == StreamState.HalfClosedLocal) {
    stream.outgoingQueue
        .enqueueMessage(ResetStreamMessage(stream.id, ErrorCode.CANCEL));
  }
});
```

`resetStream` cancels our subscription to `stream.incomingMessages` — which runs
exactly that. So on a half-closed stream the reset was already on its way,
through the stream's **outgoing queue**, in order behind our own frames. Then
`terminate()` wrote a second one **directly**, out of band. That is what the
server answers with a GOAWAY.

Which is why round 387's ablation looked like it removed cancellation and did
not: it removed only the duplicate.

**The guard is the one `releaseStreamId` has used all along**, 130 lines up in
the same file: terminate only a stream we have NOT half-closed. RPC-25 for the
fourth round running, and the sibling was the answer again.

No grace, no timer, and no trade — which is why it was shipped in place of what
the owner picked. Cancellation keeps working on both paths; the delay the grace
would have added to every abandoned download does not exist.

## After

```
link     consumer lets go at   result
direct   the last payload      5 of 5 clean
direct   onDone (the trailer)  5 of 5 clean
50 ms    the last payload      5 of 5 clean      <- was DEAD from call 2
50 ms    onDone (the trailer)  5 of 5 clean
```

**And HTTP/2's duplex column, the thing round 385 reported as broken, is clean
on both links** (P-77):

```
                  direct link            +50 ms round trip
fullDuplex        30/30 ORDER PRESERVED  30/30 ORDER PRESERVED
concurrent        8 of 8 clean           8 of 8 clean
sequential        8 of 8 clean           8 of 8 clean
residue           0, usable              0, usable
```

Round 385 read `c0:MISMATCH | ... | c7:MISMATCH` and a dead connection there.

## Canary

`if (1 > 0 || !halfClosed)` — the unconditional terminate restored:

```
WITNESS: letting go before the trailer does not cost the connection
  Expected: 'pong'
    Actual: 'DEAD: HTTP/2 connection to 127.0.0.1:62283 failed while stream 9
             was in flight (errorCode: 1); reconnect and retry'
  the connection died after call 2
```

`errorCode: 1` is PROTOCOL_ERROR, which names the double reset for what it is.

**The GUARD is the half this fix could have broken** — an abandoned download
must still stop the server's handler, since that path now relies on the
dependency's reset rather than ours. It stayed green under the canary and
passes after it, and P-77's `consumerCancel` and `tokenCancel` arms read
`handlers=0` at all three scales on both links.

## Gate

`melos run analyze` clean over 21 packages + wasm; `format:check` clean;
`license:check` 1487/1487; workspace suite **SUCCESS in all 15 packages** —
rpc_dart_http2 **+219 ~1**, rpc_dart +1558 ~1.

## Not fixed

**B-53's other half, and round 388 is what separated them.** Unskipping round
384's http2 witness showed it still fails, because that path is a different wire
state:

- **fixed here** — the consumer lets go AFTER the half-close, trailer in
  flight. `_halfClosedLocal` is true, the dependency sends the reset, we no
  longer duplicate it. This is the ordinary case: `.take(n)`, a `break`, a UI
  closing a subscription.
- **still open** — the request producer ERRORS, so the stream was never
  half-closed. The dependency sends nothing, rpc_dart's own RST_STREAM is the
  only thing that stops the handler, and sent while the server is mid-response
  it still costs the connection.

The second needs what round 387 already identified: a way to know the peer has
finished before resetting, which `package:http2` does not expose. That witness
is skipped again, naming the narrower reason.

## Links

- RPC-25 — the lens; `applied:` gains 388. Fourth round running, and the fourth
  time the sibling in the same file held the answer
- B-53 — half closed, half open, and the halves are now named separately
- P-78 — reused unchanged; P-77 — re-run, duplex column now clean
- Round 387 — the ablation that made this findable; round 385 — the trigger
- B-12 — the neighbouring defect at the same address, still open
