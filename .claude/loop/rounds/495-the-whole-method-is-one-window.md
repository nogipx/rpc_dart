---
round: 495
verdict: FIXED
packages: [rpc_dart_websocket]
lens: RPC-19
bench: P-133 — new
commit: yes
---

# Round 495 — the whole method is one window

## Target

B-104, eleventh in the audit's rank and the third websocket lead in a row, so the
rig was in hand.

Lens RPC-19 — one flag, two lifecycle meanings — and specifically its round-359
extension: *"a flag written from a `catch` describes an outcome, and an outcome
is not a state; extend the detector from WRITERS to DURATIONS."* Round 359 asked
that question of this very flag and fixed one segment of one method. This asks it
of the segments it left.

## Hypothesis

`_disconnected` is set after `_fwdSub.cancel()` and `_inner.close()`, and a
websocket close waits on the peer, so a call in that window is told
FAILED_PRECONDITION where UNAVAILABLE was meant. Refuted if the window were a
hairline, or if some other guard answered first.

## Before

```
                          status                              health
inside the CLOSE await    RpcClosedException, 9, not retryable  closed
inside the FACTORY await  RpcNoConnection,   14, RETRYABLE      degraded
no reconnect in flight    no throw                              healthy
```

Probe: `packages/transport/rpc_dart_websocket/.dart_tool/probe/b104_reconnect_window.dart`

The exception type is exactly what the lead predicted, `RpcClosedException`. And
`health()` carries a **second finding the lead does not name**: it read CLOSED —
terminal — because it delegates to an inner transport that is already closed. A
supervisor polling health during a recovery was told the transport was gone for
good.

## Mechanism

The flag described the OUTCOME of the teardown rather than the state during it,
which is round 359's own diagnosis one segment earlier. `_ensureUsable` therefore
passed, the call reached a closed inner, and `RpcChannelTransport` answered for
itself — correctly, from its own point of view, with a terminal status.

## After

```
inside the CLOSE await    RpcNoConnection, 14, RETRYABLE   degraded
inside the FACTORY await  RpcNoConnection, 14, RETRYABLE   degraded
no reconnect in flight    no throw                          healthy
```

One line moved: `_disconnected = true` above the first await. Nothing can observe
the gap between it and `reconnect()`'s `_reconnecting = attempt`, because the
prologue has no await between them — which is what makes `reconnecting: true`,
and so status 14, the answer the caller gets.

## Canary

The flag put back below the two teardown awaits — the WITNESS fails with
`Expected: <Instance of 'RpcStatusException'> with statusCode: <14> / Actual:
RpcClosedException:<RpcStatusException(9): Transport is closed>`. The CONTROL
(the factory window) and both GUARDs stay green.

The second guard is the one that makes moving a flag earlier safe: with no
reconnect in flight the transport must still read `healthy / no throw`, and after
a completed reconnect it must read that again. A flag set too early and never
cleared passes both witnesses.

## Gate

`melos run analyze` SUCCESS over 21 packages plus rpc_dart_wasm;
`melos run test:unit --no-select` SUCCESS; `melos run format:check` SUCCESS;
`melos run license:check` compliant.

## Not fixed

**The duration of the real window is unmeasured.** The bench holds it open for a
chosen 600 ms; what dart:io actually waits for a close frame the peer never sends
is reported as seconds by B-134 and is not confirmed here.

`health()` still delegates to `_inner` whenever `_disconnected` is false, so any
future state where the inner is closed and the flag is not would report CLOSED
again. The flag now covers the whole of `reconnect()`, which is the only path
that closes the inner without closing the wrapper — so there is no such state
today.

## Links

Lens RPC-19, whose round-359 section is the same question one segment earlier.
Bench P-133 (new). Lead B-104 (closed). B-134 is the seconds-long close this
window is made of.
