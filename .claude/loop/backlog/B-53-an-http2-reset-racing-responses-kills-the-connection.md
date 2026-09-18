---
status: open
round: 384
commit: 69d24a76
paths: [packages/transport/rpc_dart_http2/lib/**, packages/core/rpc_dart/lib/src/rpc/streams/base_processor.dart]
probe: packages/transport/rpc_dart_http2/.dart_tool/probe/abort_kills_the_connection.dart
reason: owner decision — the fix that removes the leak makes this reachable automatically, so http2 trades a permanent leak for a connection that can still die under load; and the cause is inside package:http2's reset handling, which is B-12's family
---

# B-53 — an HTTP/2 stream reset that races in-flight responses kills the connection

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
