---
status: decided by owner (round 247)
round: 241
commit: aaa5806d
paths: [packages/transport/rpc_dart_http2/lib/src/transports/http2/rpc_http2_caller_transport.dart]
probe: packages/transport/rpc_dart_http2/.dart_tool/probe/reconnect_orphan_rate.dart
reason: risk — the candidate fix did not measurably lower the rate and moved the failure onto the LIVE connection; at ~1.3% no deterministic witness exists, and shipping an unproven change to the connect path is worse than the leak
---

# B-25 — a sequential reconnect orphans a connection about 1.3% of the time

Reported twice by the owner from full-suite runs, as
`concurrent_reconnect_test.dart` -> "GUARD: a later reconnect still opens a new
connection", `Expected: <0> Actual: <1>`. It does not reproduce on demand: the
test passed 6/6 alone, and the whole http2 suite and a whole workspace
`test:unit` passed too.

## What is measured

Bench [P-19](../probes/P-19-sequential-reconnect-orphan-rate.md), 390 cycles of
`connect -> reconnect -> reconnect -> close` on the direct path:

```
5 cycles in 390 left ONE connection open on the server 8 s after close()
0 cycles in  90 through the stalling CONNECT proxy did
```

**The orphan is always a DISCARDED connection, never the live one** — ordinals
[1], [2], [2] on the three cycles that carried the instrumentation. So `close()`
does its job; `reconnect()`'s discard of the connection it is replacing is what
sometimes fails to reach the peer.

This is NOT the defect `concurrent_reconnect_test` already pins. That one needs
two overlapping attempts and is deterministic; this one appears with two
STRICTLY SEQUENTIAL reconnects, and the 400 ms stall that makes the concurrent
race reliable produces zero orphans here.

## The mechanism, as far as it is established

`_guardedConnection` builds the connection with
`http2.ClientTransportConnection.viaStreams(guarded, outgoing)`, not
`viaSocket`. Under `viaStreams` package:http2 does not own the socket: it can
close the outgoing sink and nothing else. `_discardConnection` calls
`connection.terminate()` and stops there. The `destroy` callback that would kill
the socket is built in the same function and is wired only to a header-block
violation.

That is a coherent story for the leak and it is NOT proven.

## The candidate fix, and why it was reverted

Attaching `destroy` to the connection through an `Expando` and calling it from
`_discardConnection` after `terminate()`:

```
                     cycles  orphaned   which
before                 390      5       discarded (1 or 2)
with the destroy call  150      1       the LIVE connection (3)
```

1 in 150 against 5 in 390 is 0.67% against 1.28% — at these counts, noise; 150
cycles expect two orphans if nothing changed. And the single post-fix orphan was
the live connection, a mode that never appeared in 390 cycles before, which is
either a second defect or something the change introduced. Reverted rather than
shipped: this loop does not ship a fix with no failing witness, and a 1.3%
probabilistic defect cannot produce one.

## The mechanism hunt — round 255

`ClientTransportConnection.terminate()` reaches
`Connection._terminate` (`http2-2.3.1/lib/src/connection.dart:410`), which does
two asynchronous things and returns a Future:

```dart
_outgoingQueue.enqueueMessage(GoawayMessage(...));      // :418, queued
var closeFuture = _frameWriter.close().catchError(...); // :423
```

Under `viaStreams` the frame writer IS the only thing holding the socket's write
side, so that `close()` is what produces the FIN. It is queued behind whatever
`_outgoingQueue` already holds, and it is asynchronous.

**And `_discardConnection` throws the Future away.** It is `void`, calls
`connection.terminate()`, and moves on — so the discard is fire-and-forget. If
the outgoing queue is not drained promptly, or the sink is paused by OS-level
backpressure, the close simply has not happened yet; nothing waits for it and
nothing retries. That is a coherent account of a failure that happens 1.3% of
the time rather than always: it needs the queue to be non-empty at exactly that
moment.

It also **redirects the fix**. Round 241 tried `socket.destroy()` and measured
noise. If this reading holds, the answer is to stop discarding the Future —
await it, or race it against a short deadline and only then destroy — which is
a different change from the one already refuted.

**Measured in round 256, and REFUTED.** Driven against package:http2 directly,
no rpc_dart internals, doing exactly what `_discardConnection` does — call
`terminate()`, keep nothing — with one variable: whether bytes are queued at
that moment.

```
arm    terminate() pending at 0ms / 50ms    server saw close
idle          20/20        0/20                    20
busy          20/20        0/20                    20
```

Probe: `packages/transport/rpc_dart_http2/.dart_tool/probe/terminate_future_pending.dart`.

The Future is pending immediately in every case, because it is asynchronous, and
complete within 50 ms in all forty — including with 128 KiB sitting in the
outgoing queue. The server registered every close. So dropping the Future is
real but harmless at this scale, and it is not what leaves a connection open for
more than eight seconds.

**Two accounts now refuted**: `socket.destroy()` as the fix (round 241, measured
as noise) and the dropped `terminate()` Future as the cause (this one). The 1.3%
still has no mechanism, and the honest state of this lead is that its cause is
unknown rather than suspected.

**Correction, round 257:** the note first written here pointed at the proxy
path's second socket, which is backwards — every orphan came from the DIRECT
arm and the stalled-proxy arm produced none in 90 cycles. The proxy is where
the problem is NOT.

**What the refuting probe did differently from the real code, and it is one
thing.** Round 256 built its connection as
`ClientTransportConnection.viaStreams(socket, socket)`. `_guardedConnection`
does not:

```dart
final guarded = guardHttp2HeaderBlock(incoming, ...);   // a WRAPPER
return http2.ClientTransportConnection.viaStreams(guarded, outgoing);
```

The incoming side is a transformed stream. `_terminate` closes the connection
by, among other things, `_frameReaderSubscription.cancel()` — a cancel of the
subscription to the **guarded** stream, not to the socket. If that wrapper does
not propagate cancellation to its source, the socket's READ side stays open,
and a socket with a live read side is a connection the server still counts.

That is the difference between a probe that saw 0 failures in 40 and production
code that fails 1.3% of the time, and it is the RPC-10 shape exactly: a wrapper
that drops a capability of the thing it wraps. It is also why round 241's
`socket.destroy()` looked like it half-worked — destroy kills both directions,
so it papered over a read side nobody closed.

**Refuted in round 258 before it cost a probe**, by reading the wrapper's last
line (`http2_header_block_guard.dart:91`):

```dart
controller.onCancel = () => sub.cancel();
```

It DOES propagate cancellation to its source. So `_frameReaderSubscription
.cancel()` reaches the socket subscription after all, and the wrapper is not
dropping that capability.

**Three accounts refuted now.** What the reading did leave behind is a sharper
question, and it is about dart:io rather than about this library: cancelling a
`Socket`'s stream subscription stops reading, it does not CLOSE the socket. So
after `terminate()` the write side is closed by the frame writer and the read
side is merely unsubscribed — the socket is half-closed and depends on the peer
to finish it. That is normally invisible, because the server sees the FIN, ends
its own connection and counts the close.

The 1.3% would then be whatever prevents that FIN from being written, and
`_frameWriter.close()` is the only thing that writes it.

**Round 259 followed that to the bottom and it is ordinary:**

```
terminate() -> _frameWriter.close()            frame_writer.dart:276
            -> BufferedBytesWriter.close()     async_utils.dart:121
            -> _bufferedSink.sink.close()      the socket's write side
```

That is precisely the path round 256's probe exercised, with the same socket
object as `outgoing`, and it produced 0 failures in 40. So the write side is not
where the difference lives either.

**What is left, and it is the one thing no attempt has varied.** Production does
not terminate a connection in isolation: `_reconnectOnce` discards the old
connection and then immediately awaits the factory for a NEW one, so a discard
is always racing a connect on the same event loop, and the failing test does it
twice in a row. Every probe so far terminated a connection with nothing else
happening.

That is a better fit for 1.3% than anything refuted so far — a race needs a
coincidence, and the three dead accounts were all unconditional.

**Round 260 tried it and did not reproduce it** — with a caveat that matters
more than the result:

```
arm    terminate() pending at 0ms / 50ms    server saw close
idle          20/20        0/20                    20
busy           0/20        0/20                    40
```

All forty connections closed. But the `busy` arm now varies TWO things at once,
the queued bytes and the racing connect, so a positive result would have been
ambiguous and this negative one is weak: it says "not reproduced by this pair of
changes together", which is nearly worthless. The control rule was broken inside
the probe, by the round that wrote it.

**So the race is neither confirmed nor cleared.** Redoing it properly means
three arms — idle, queued-only, race-only — and that is what the next attempt
should build before adding anything else.

**Four rounds on this hunt (255-260) and the cause is still unknown.** That is
worth saying plainly rather than burying: the lead is better bounded than it
was — three mechanisms eliminated by measurement or reading, the FIN path traced
to the bottom — but nobody should read this section as closing in. The owner's
"hunt the mechanism first" has not paid out, and the fallback they declined,
2000 cycles an arm, is now the cheaper option of the two.

## Owner decision

**Hunt the mechanism first** (round 247). Do NOT spend 2000 cycles an arm on a
rate comparison. Find what makes the outgoing sink's close fail to reach the
peer in ~1.3% of discards; a deterministic reproduction gives a real canary and
makes the powered rate measurement unnecessary.

That reorders what the "what would close it" section lists: the mechanism hunt
is now the first move, and the 75-minutes-per-arm measurement is the fallback if
the hunt comes back empty.

## What would close it

A deterministic reproduction — the shape to look for is what makes the sink
close fail to reach the peer, since that is the difference between the 98.7% and
the 1.3%. Failing that, a rate measurement powered enough to separate 1.3% from
0.65%: roughly 2000 cycles an arm, about 75 minutes each, which is the cost this
lead is deferred on.
