---
refines: U-07
paths: [packages/core/rpc_dart/lib/src/resilience/**, packages/transport/rpc_dart_websocket/lib/**, packages/transport/rpc_dart_http2/lib/**, packages/transport/rpc_dart_http/lib/**, packages/transport/rpc_dart_isolate/lib/**]
applies: a lifecycle flag is read, then a slow external operation is awaited, then the result is installed
breaks: a connection leak.
applied: [235]
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
