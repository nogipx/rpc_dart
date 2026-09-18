---
round: 385
verdict: DEFERRED
packages: [rpc_dart_isolate, rpc_dart_http2]
lens: RPC-10
bench: P-78 — new
commit: yes
---

# Round 385 — the consumer that let go one beat early

## Target

Finishing the owner's goal where round 384 left it: websocket had the full
endings-and-duplex matrix on real wire, **isolate and http2 had only the
request-sink question**. This round takes the same matrix to both, in the
owner's priority order.

RPC-10 — what does a transport have to re-implement, and did it? — because that
is exactly the question a per-transport port of one matrix asks.

Two things were added rather than copied, one per transport:

- **isolate: zero-copy.** Its channel supports codec-less calls, a second branch
  through `_ensureBidirectionalResponder` that no endings matrix has ever run.
- **http2: the `usable` column earns its keep.** Two of the seven endings go out
  as RST_STREAM here, which is B-53's own primitive.

## Hypothesis

At least one of the two transports does not carry an ending or a duplex case
that websocket carries.

## Before

**Isolate — clean, in both modes.** Seven endings, three scales, one spawned
worker per arm, counters reported over the wire by a unary method (the worker's
own pipeline cannot be read from here). The `open=1` baseline is the stats call
itself, which is what the unary arm is for:

```
arm                serialized            zero-copy (no codecs)
unary (control)    baseline, usable      n/a
normal             baseline, usable      baseline, usable
consumerCancel     baseline, usable      baseline, usable
tokenCancel        baseline, usable      baseline, usable
handlerThrows      baseline, usable      baseline, usable
deadline           +5 / +12 / +12        +5 / +12 / +12
neverFinish        baseline, usable      baseline, usable
fullDuplex         30/30 ORDER PRESERVED 30/30 ORDER PRESERVED
concurrent         8 of 8 clean          8 of 8 clean
```

The two modes are identical in every cell, and the `deadline` row is the same
bounded `_reclaimGrace` retention websocket shows. Probe:
`rpc_dart_isolate/.dart_tool/probe/bidi_endings_over_isolate.dart` (P-76).

**HTTP/2 — the endings are clean on both links**, including the two that reset:

```
arm                direct link            +50 ms round trip
every ending       0 everywhere, usable   0 everywhere, usable
fullDuplex         30/30 ORDER PRESERVED  30/30 ORDER PRESERVED
```

**And then the duplex section killed the connection over the latent link.**
Not the duplex itself — the arms that followed it. Splitting them onto separate
connections and adding a sequential arm located it: the connection dies after
calls that had COMPLETED (P-77).

The isolating bench is four arms differing by exactly when the consumer lets go
(P-78), five mirror calls of 12 messages each, pinging after every one:

```
link     consumer lets go at   result
direct   the last payload      5 of 5 clean
direct   onDone (the trailer)  5 of 5 clean
50 ms    the last payload      DEAD from call 2   <- the SERVER closed
50 ms    onDone (the trailer)  5 of 5 clean
```

## Mechanism

A consumer that stops reading as soon as it has the messages it wanted —
`.take(n)`, a `firstWhere`, a `break` out of `await for`, a UI closing a
subscription — cancels while the server's trailer is still on the wire. The
cancel becomes RST_STREAM. Over a link with any round trip the server has by
then already sent END_STREAM and closed its side, so the reset lands on a stream
that is closed server-side, and the connection goes down with it. On a direct
link the trailer has already arrived, so the consumer never resets at all.

**Which side, and why no log names it.** The relay reports `server closed`, and
with a `LogController` attached to the server the arms divide sharply:

```
direct link   5x "Error in bidi handler | RpcCancelledException: peer sent
              RST_STREAM (errorCode: 8)"  — handled, connection survives
50 ms link    nothing at warning or above, and the connection is gone
```

So the death does not pass through any of rpc_dart's error paths. It is below
them, in `package:http2`'s server connection, which is also where B-12's
mechanism lived. Resetting a stream whose END_STREAM has not yet been received
is legal for a client; tolerating that reset is the server's job.

## After

n/a — nothing changed. `git diff --stat` empty before the verdict.

One candidate was tried and **refuted by measurement**: `RpcHttp2OutgoingPump`
attaches an error handler to its `addStream` future only inside `_finish()`, so
a stream reset before END_STREAM leaves it unhandled. Handling it at
construction changed nothing — the connection still died, one call earlier.
Reverted rather than kept, because a change that fixes nothing is not a fix.

## Canary

n/a — no fix. The evidence is the four-arm matrix, where each arm differs from
its neighbour by one variable: the link, or the instant the consumer lets go.
The two clean arms are what make the dead one mean something — in particular
`50 ms, after done`, which is the same link, the same calls and the same cancel,
moved one event later.

## Gate

No library code moved, so round 384's gate stands. The probes are
`.dart_tool/probe/`, outside analysis and the suite.

## Not fixed

**B-53, updated rather than duplicated** — this is the same defect with a far
more ordinary trigger and, now, the side identified. What this round adds to it:

- the trigger needs no `abort()` and no erroring sink: an ordinary consumer
  cancelling one event early does it;
- it needs latency, which every deployment has and no bench before P-74 had;
- the SERVER closes the connection, and rpc_dart logs nothing, so the cause is
  inside `package:http2`.

Every rpc_dart-side lever is a behaviour trade rather than a repair — suppress
the reset when the response may be complete, or delay the cancel until the
trailer — and that is the owner's call, as it was in B-12 and B-27.

Not covered: links slower than 50 ms, packet loss, a connection that drops
mid-call, dart2js, RSS. Websocket and isolate do not have this defect; their
cancellation is a metadata frame, not a stream reset.

## Links

- RPC-10 — the lens; `applied:` gains 385
- P-76, P-77, P-78 — the three benches
- C-45 — the isolate negative, both modes
- C-44 — the websocket half, round 384
- B-53 — updated with this round's trigger, matrix and side attribution
- B-12 — the same family: a per-stream event costing the whole connection
- L-15 — why the `deadline` row is read against `_reclaimGrace` and not as zero
