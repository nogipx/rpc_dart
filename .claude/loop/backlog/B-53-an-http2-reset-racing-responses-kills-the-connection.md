---
status: open — the ordinary half FIXED in round 388, the not-half-closed half remains
round: 384
commit: 69d24a76
paths: [packages/transport/rpc_dart_http2/lib/**, packages/core/rpc_dart/lib/src/rpc/streams/base_processor.dart]
probe: packages/transport/rpc_dart_http2/.dart_tool/probe/abort_kills_the_connection.dart
reason: owner decision — the fix that removes the leak makes this reachable automatically, so http2 trades a permanent leak for a connection that can still die under load; and the cause is inside package:http2's reset handling, which is B-12's family
---

# B-53 — an HTTP/2 stream reset that races in-flight responses kills the connection

> **Round 388 fixed the ordinary half and, in doing so, separated the two.**
> `package:http2` ALREADY sends the reset itself — `stream_handler.dart:332`,
> `streamQueueIn.onCancel` enqueues a `ResetStreamMessage` when the state is
> `HalfClosedLocal`, and `resetStream` cancelling our incoming subscription is
> what runs it. That one goes through the stream's **outgoing queue**, in order.
> `terminate()` then wrote a SECOND one directly, out of band, and the server
> answers a double reset with GOAWAY `errorCode: 1` (PROTOCOL_ERROR). The guard
> is the one `releaseStreamId` has used all along, 130 lines up: terminate only
> a stream we have not half-closed. No grace, no timer, no trade.
>
> ```
> link     consumer lets go at   before             after
> 50 ms    the last payload      DEAD from call 2   5 of 5 clean
> ```
>
> And HTTP/2's duplex column — `fullDuplex`, `concurrent`, `sequential` — is
> clean on both links, where round 385 read eight MISMATCHes and a dead
> connection.
>
> **What remains is the case where the stream was never half-closed**: the
> request producer ERRORS instead of completing, so the dependency sends
> nothing and rpc_dart's own RST_STREAM is the only thing that stops the
> handler. Sent while the server is mid-response it still costs the connection.
> Round 384's http2 witness is skipped again, naming that narrower reason.
>
> Closing it needs what round 387 identified: knowing the peer has finished
> before resetting, which `package:http2` does not expose. The upstream request
> is now precise — a stream-state getter, or an ordered reset for a stream that
> is not half-closed.

> **Round 385 widened this and answered its first question.** The trigger needs
> no `abort()` and no erroring sink. **A consumer that stops reading as soon as
> it has the messages it wanted** — `.take(n)`, a `firstWhere`, a `break` out of
> `await for`, a UI closing a subscription — cancels while the server's trailer
> is still on the wire, and over a link with any round trip that costs the whole
> connection. P-78, five mirror calls of 12 messages, pinging after each:
>
> ```
> link     consumer lets go at   result
> direct   the last payload      5 of 5 clean
> direct   onDone (the trailer)  5 of 5 clean
> 50 ms    the last payload      DEAD from call 2   <- the SERVER closed
> 50 ms    onDone (the trailer)  5 of 5 clean
> ```
>
> **Which side: the server**, per the relay's own attribution. **And rpc_dart
> logs nothing** — with a `LogController` attached, the direct arm prints five
> handled cancellations (`peer sent RST_STREAM (errorCode: 8)`) and survives,
> while the latent arm prints nothing at warning or above and dies. So the
> cause is below rpc_dart, inside `package:http2`'s server connection — B-12's
> address.
>
> Sequence: the server sends its trailer and closes its side; the client, which
> has not yet seen that trailer, cancels and sends RST_STREAM; the reset lands
> on a stream that is closed server-side. Resetting a stream whose END_STREAM
> has not been received is legal for a client (RFC 9113), so tolerating it is
> the server's job.
>
> One candidate was tried and refuted: `RpcHttp2OutgoingPump` leaves its
> `addStream` future unhandled unless `_finish()` runs, and a stream reset
> before END_STREAM never reaches it — handling it at construction changed
> nothing. Reverted.
>
> This raises the severity a long way. The original entry needed an erroring
> request sink or an explicit `abort()`; this needs an ordinary consumer and a
> network.

> **Round 387 proved the trigger and killed the two cheap guards.**
> `stream.terminate()` removed from `resetStream`, nothing else changed:
> the `50 ms / let go at the last payload` arm goes **DEAD from call 2 -> 5 of 5
> clean**, the other three arms unchanged. So the RST_STREAM is what costs the
> connection and nothing else in the teardown does.
>
> Dead ends, measured so nobody pays twice: gating the reset on
> `_statusReceived` never fires, because that set is filled when *rpc_dart*
> parses the trailer and in this race it has not; and round 385's outgoing-pump
> candidate was already refuted.
>
> **The dependency's own code says this should be harmless**, which is why it
> needed an ablation. In `http2-2.3.1`: `_terminateStream`
> (`stream_handler.dart:406`) writes RST_STREAM only for a stream in an open-ish
> state, so terminating a closed one is a no-op; and an incoming `RstStreamFrame`
> for an unknown stream is a connection error **only if idle**
> (`streamId > lastRemoteStreamId`), which this is not — the comment there reads
> *"RstFrames for already dead (known as 'closed') streams should be ignored"*.
> Both guards read correct and the connection still dies, so what remains is
> between them and inside `package:http2`.
>
> **Why the obvious fix is a trade.** Suppressing the reset for a stream we have
> already half-closed fixes this and breaks what cancellation is FOR: a client
> that half-closes at once and then abandons a long server-stream download needs
> that reset to stop the server. Both are `HalfClosedLocal` plus a cancel, and
> rpc_dart cannot tell them apart without knowing the peer has finished — which
> is exactly what it learns too late.
>
> Two routes that are NOT trades: ask `package:http2` for the stream state
> before terminating (its public API does not expose it — a small upstream
> feature request), or report it upstream, where the reproduction is now four
> arms and one ablated statement.

On HTTP/2 `_notifyPeerOfCancellation` goes out as RST_STREAM
(`IRpcStreamReset.resetStream` -> `stream.terminate()`). When it lands while the
server is still writing responses for that stream, the **whole connection**
dies: every other call on it then fails with

```
RpcStatusException(14): HTTP/2 connection to 127.0.0.1:NNNNN is no longer
active (the peer closed it or sent GOAWAY); reconnect and retry
```

`!_connection.isOpen`, no GOAWAY recorded, no active streams — so the client's
own http2 connection is finishing or terminated.

## What the matrix eliminates (P-73, five calls per arm)

```
arm                                    handler   abort timing        connection
abortWhileEmitting                     answers   30 ms settle        alive
abortWhenIdle                          silent    30 ms settle        alive
abort racing responses, awaited        answers   no settle           DEAD
abort racing responses, unawaited      answers   no settle           DEAD (races)
sinkErrors, before 384's close         answers   from onError        DEAD
sinkErrors, with 384's close           answers   from onError        alive (alone)
endpoint API, erroring requests        answers   via cleanup()       alive
halfClose (control)                    answers   finishSending       alive
```

Not the await — the awaited arm dies. Not round 384's sink path — the raw public
`abort()` dies with none of that code in it. What every dead arm shares is
**responses in flight at the instant of the reset**, and every live arm either
has no responses or has let them drain.

## Why it is filed rather than fixed

Round 384 fixed a permanent server-side leak by making an erroring request sink
tell the peer. On websocket and isolate the notice is a metadata frame and both
are clean. On http2 it is a reset, so that fix walks straight into this.

Adding `close()` after the notice — which is what `ClientStreamCaller` does, and
what the round shipped — narrows the window enough that the case is clean run
alone, and **not** enough under load: the http2 witness still failed with the
GOAWAY inside the workspace gate, so that one test file is `@Skip`ped naming
this item.

That leaves a trade this round would not make for the owner: on HTTP/2 an
erroring request sink goes from *a permanent leak on a live connection* to *no
leak on a connection that can still die*. The same shape as B-12, where the
owner's answer was "safety for safety is mine to decide".

## Owner decision

**Not yet taken — this is the question.** On HTTP/2 an erroring bidi request
sink now goes from *a permanent server-side leak on a live connection* to *no
leak on a connection that can still die under load*. Round 384 would not make
that trade on the owner's behalf; it shipped the fix (the leak is gone on
websocket and isolate, which the owner ranked first) and skipped the http2
witness rather than pretend either half was settled.

Three ways out, and the cost of each:

1. **Fix the reset path in `rpc_dart_http2`** so a reset cannot take the
   connection with it. The right answer if the cause is ours; unknown size
   until step 1 of "Where to start" is done, and it may be inside
   `package:http2`, which is B-12's family.
2. **Do not reset on http2 when responses may be in flight** — drain or
   half-close first. Changes what a cancelled call costs and is a behaviour
   decision in its own right.
3. **Accept it and document it**: `abort()` on http2 may cost the connection.
   Costs every other call on a shared connection, silently.

## Where to start

1. **Establish which side closes it.** The probe reads only the client's
   verdict. Attach a logger to both ends, or watch whether a second client can
   still connect to the same server afterwards.
2. The likely candidate is the SERVER writing a response to a stream the client
   has just reset — `package:http2` surfaces that asynchronously, which is why
   no try/catch on the rpc_dart side sees it. `releaseStreamId` already carries a
   comment about exactly this class: *"package:http2 treats that as a CONNECTION
   error and terminates the connection ... and the throw is asynchronous so the
   try/catch below never sees it."*
3. C-32 is not a counter-example: its 200 resets landed BEFORE dispatch, so the
   server never wrote anything.
4. The witness already exists — unskip
   `rpc_dart_http2/test/request_sink_error_over_http2_test.dart` and run the
   workspace gate, which is where it fails.
