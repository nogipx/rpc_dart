---
refines: U-07
paths: [packages/core/rpc_dart/lib/src/resilience/**, packages/transport/rpc_dart_websocket/lib/**, packages/transport/rpc_dart_http2/lib/**, packages/transport/rpc_dart_http/lib/**, packages/transport/rpc_dart_isolate/lib/**]
applies: a lifecycle flag is read, then a slow external operation is awaited, then the result is installed
breaks: a connection leak.
applied: []
status: derived
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

— as a lens. No round in this journal has applied it; the four instances above
predate the journal and are cited by sha, not by round number, because their
round numbers are not recoverable from the commits.

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
