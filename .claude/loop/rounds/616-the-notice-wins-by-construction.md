---
round: 616
verdict: CLEAN
packages: [rpc_dart_websocket]
lens: RPC-16
bench: P-219 — reused
budget: probes 1/5, canaries 1/5
commit: yes
release: none
---

# Round 616 — the notice wins by construction

## Target

B-212's second half. The reconnect notice that reclaims a parked peer call is
emitted before the reconnect's awaits, and every measured run had a whole
handshake between it and the new socket's first frame. Nothing removed that
handshake. If the new call's opening frame ever reached the pipeline first, the
notice would cancel the NEW call.

## Hypothesis

The ordering holds only because a socket takes time to open, so a reconnect
whose next socket is already open and already carrying the new call's opening
frame cancels that call.

## Before

P-219 with a `frameFirst` arm. The next socket is opened before `reconnect()`,
the server's fresh endpoint opens the second call on it at once, and after
100 ms the frame is waiting in the socket when it is attached:

```
                 second caller    cancelled
unary            answered two     [one]
server-stream    answered two     [one]
client-stream    answered two     [one]
bidi             answered two     [one]
```

REFUTED for all four shapes.

## Control

The ordinary reconnect arm and the no-reconnect guard, same rig, unchanged.

## Mechanism

`_reconnectOnce` calls `_abandonPeerStreams` before its first `await`, and since
round 615 the wrapper forwards synchronously, so the notice reaches the
pipeline before any later event. Its reclamation needs only microtasks. The new
socket's first frame needs at least an I/O event, and it cannot be attached until
`_inner.close()` and the factory have both returned. So the ordering is a
property of the code, not of how long a socket takes to open.

## After

n/a — no change.

## Canary

The notice moved to just after `_attach` (with a 50 ms wait): all four shapes
fail the `frameFirst` arm with `secondGot: TIMEOUT` and the new call never
started. The arm can see the race. Restored; `lib/` is byte-identical to the
previous commit.

## Gate

`a_reused_peer_id_streaming_shapes_test.dart` and
`a_reused_peer_id_gets_its_own_answer_test.dart` (+16), websocket package
analyzed, the file format-checked. `lib/` byte-identical.

## Not fixed

Nothing in B-212. What round 615 exposed is filed as B-226: a decorator that
re-broadcasts asynchronously, which nothing here controls, breaks peer bidi
the same way.

## Links

Lead `../backlog/B-212-the-streaming-shapes-tail-cleanup-is-unmeasured.md` — closed.
Lead `../backlog/B-226-the-bind-relies-on-microtask-order.md` — new.
Bench `../probes/P-219-the-streaming-shapes-across-a-reconnect.md` — reused, `frameFirst` arm added.
Lens `../lenses/RPC-16-check-before-await.md` — `applied: [..., 616]`.
