---
refines: U-07
paths: [packages/core/rpc_dart/lib/src/resilience/**, packages/core/rpc_dart/lib/src/endpoint/**, packages/transport/rpc_dart_websocket/lib/**, packages/transport/rpc_dart_http2/lib/**, packages/transport/rpc_dart_http/lib/**, packages/transport/rpc_dart_isolate/lib/**]
applies: something is read, then an operation is awaited, then the read is relied on — a lifecycle flag, or an open iterator over a mutable collection
breaks: a connection leak; or an in-flight call failing with a StateError instead of its status.
applied: [235, 505, 510]
status: confirmed (round 235)
---

# RPC-16 — The guard read before the await

## Shape

A method asks "am I still wanted?", then awaits something slow — opening a
socket, spawning an isolate, a handshake — then acts on what came back, without
asking again. `close()`/`dispose()` lands inside that window routinely, because
the await is a network operation measured in tens to hundreds of milliseconds.
Two damages, and the second is worse: the thing the factory produced is
orphaned (nobody holds it, so nobody can close it), and the installing code may
resurrect state the caller had already torn down.

## Detector

Every `reconnect`, `connect`, `spawn` and `attach` in the classes above. For
each: does the closed/stopped flag get read BEFORE an `await`, and does anything
re-read it after? Then the second half — when the guard does fire late, is what
the factory returned CLOSED, or merely dropped?

**Four instances are already fixed, and they are the detector's calibration —
each is a live comment in the code, so a sweep that does not find them is a
broken sweep:**

    334b3337  RpcClientConnection._connectWithBackoff   50 leaked sockets in 50
                                                        iterations; dispose()
                                                        could reclaim none
    8128e3cd  RpcClientConnection connectTimeout        49 leaked sockets in
                                                        1.2 s, unbounded
    32966691  RpcWebSocketCallerTransport.reconnect     1 socket per race;
                                                        websocket_caller_transport.dart:443
    48847ffc  RpcHttp2CallerTransport.reconnect         leaked the connection AND
                                                        set _isClosed = false, so
                                                        the transport un-closed
                                                        itself and reported
                                                        HEALTHY after shutdown;
                                                        rpc_http2_caller_transport.dart:1744

Regression tests: `reconnect_close_race_test.dart` in both rpc_dart_websocket
and rpc_dart_http2.

## Ask

Does `close()` landing inside the await window leave anything alive that nothing
holds a reference to?

## Evidence

**Round 235 swept the 15-site instance list and found a fifth instance**, in the
half of the detector that asks what happens on the failure path rather than
whether the flag is re-read. `_ReconnectingTransportProxy.detach()` awaited
`_innerSub!.cancel()` unguarded and only then closed `_inner` inside a
`try/catch` — three lines apart from `_retire`, which guards its close with
`.catchError`. `incomingMessages` belongs to a transport the FACTORY built, so
that `onCancel` is user code:

    control        built=2 closed=2 leaked=0 unhandled=0 disposeThrew=false
    cancel THROWS  built=1 closed=0 leaked=1 unhandled=1 disposeThrew=true

Three damages from one unguarded await: the transport dropped rather than closed
with nothing able to reclaim it; `forceReconnect()` skipping the reconnect AND
leaking the rejection to the zone (the ROOT zone in an application, where it
ends the isolate); and `dispose()` throwing, leaving `_msgCtl` open. Bench
`../probes/P-14-detach-with-a-throwing-cancel.md`.

> **The guard STYLE around a hop is evidence about the hop.** Both neighbours of
> that cancel were guarded, by two different idioms, which says the authors did
> consider a throwing teardown — the cancel is simply the one they missed. When
> a sweep finds one unguarded await between two guarded ones, that is a finding,
> not a stylistic quibble.

The rest of the list came back clean and is recorded in
`../rounds/235-the-one-hop-nobody-guarded.md`; the isolate's VM and WEB `spawn`
are both guarded and, unusually, symmetric.

The four instances below predate the journal and are cited by sha, not by round
number, because their round numbers are not recoverable from the commits.

**Three measurement traps, each of which produced a wrong answer once. They are
the reason this lens is worth a round rather than a grep:**

1. **The window is too small on localhost.** `Socket.connect` to 127.0.0.1 is
   ~1 ms, so the race never fires. Widen it honestly: a user-supplied factory
   (websocket) can sleep; for http2 use the CONNECT-proxy path and stall the
   proxy's `200 Connection Established`.
2. **Count with an observable that works.** Server-side connection counts are
   right; `ws.done.whenComplete` and a raw `ServerSocket` that does not speak
   HTTP/2 both reported the CONTROL as leaking. Always include a plain
   connect+close control — if it does not show a clean release, the harness is
   wrong, not the library.
3. **Give teardown enough time.** A GOAWAY travelling client -> proxy -> server
   needs seconds; a 2 s settle showed a phantom leak that 4 s did not.

> **Teardown gotcha, and it is fatal rather than untidy:** never `finish()` an
> http2 connection whose socket is already gone. package:http2 throws
> `Bad state: Cannot add event after closing` from its frame writer,
> asynchronously, from a subscription created in the ROOT zone — neither
> `catchError` nor a surrounding `runZonedGuarded` catches it, and it kills the
> isolate. Use `terminate()`.

Imported from private memory in the curate pass after round 234, where it had
sat outside the journal since the pre-201 rounds: `loop.py` could not route to
it, and `stale` could not age it.

## What goes stale across the await can be the ITERATOR (round 505)

The lens was written about a lifecycle FLAG read before a suspension and trusted
after it. The same suspension invalidates something else nobody thinks of as read
state: an open iterator over a mutable collection.

```dart
for (final middleware in _middlewares) {
  current = await ...;              // close() clears the list here
}
```

A Dart `List` iterator compares modification counts on every `moveNext()`, so the
list itself is the thing that had to survive the await. One element is enough — the
`moveNext()` that ENDS the loop is the one that checks — and `.reversed` is a lazy
view of the same list, so the mirrored loop carries the identical defect.

**So the detector gains a second query beside the flag reads: every `for (final x in
<field>)` whose body awaits.** Ask who else writes that field, and remember that
`clear()` in a `close()` is ordinary, public, and expected.

> **Fixing it changes the error's TYPE, not whether the call fails.** A call
> interrupted by `close()` cannot succeed either way; before, it failed with a
> `StateError` from inside the library, and after, with `RpcCancelledException:
> Endpoint closed`. A round measuring "did the call succeed" scores such a fix as no
> change. Measure the error, not the outcome.

And the bench needs an arm with the collection EMPTY: an empty loop never awaits, so
it never observes the mutation. Without that arm, "close() breaks an in-flight call"
explains the table just as well and the fix gets aimed at `close()`.

`../probes/P-143-what-a-call-gets-when-the-list-moves.md`,
`../rounds/505-the-list-moved-under-the-call.md`, B-114.

## A synchronous MARK is only half a fix; check the READER (round 510)

`_sendGrpcErrorAndCleanup` calls `_rememberClosedStream(id)` **before its first
await**, and its comment — from an earlier round that fixed the two-frame version of
this — calls that "the whole fix". It was not. The guard consulting the set read:

```dart
if (_respStreams[message.streamId] == null &&
    _respClosedStreams.contains(message.streamId)) {
```

The state is torn down in a detached `finally`, so between the synchronous mark and
the cleanup `_respStreams[id]` is still non-null, the first condition is false, and
every further frame walks past. One call to an unregistered method was answered
THREE times — once per inbound frame, three separate `binding == null` sites, all on
one stream id.

**So when a round fixes a race by moving a WRITE earlier, follow it to every READ.**
A reader that ands the new synchronous fact with an old asynchronous one is exactly
as racy as before, and it now looks guarded. Grep the field the mark writes and read
each condition it appears in.

> **Removing a condition is the risky direction, so guard the thing it protected.**
> The dropped clause was what let a genuinely new call reuse a closed id. Two guards
> cover it: several calls in sequence (the caller reuses ids as they are released),
> and refuse-then-call-again — because if the closed-set entry were never cleared the
> next call would be ignored and hang to its deadline, which is worse than the defect
> being fixed.

> **And this was found by a COST lead.** The bench counted frames and then printed
> what each one WAS; the count alone (4, against a success's 4) said nothing.
> Decoding the payload and the stream id is what made three trailers visible as one
> call rather than three.

`../probes/P-148-how-many-frames-is-a-unary-call.md`,
`../rounds/510-one-call-answered-three-times.md`, B-119.
