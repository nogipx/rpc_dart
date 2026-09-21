---
round: 422
verdict: FIXED
packages: [rpc_dart, rpc_dart_http2, rpc_dart_websocket]
lens: RPC-25
bench: none — four mechanics with no shared owner; the evidence is one ablation
  whose reading is the whole point, plus the sweep's own counts
commit: yes
---

# Round 422 — the number that decided a shutdown

## Target

**B-63's four remaining mechanics**, the owner's pick. Its largest item closed
in round 416; these are what was left.

Ranked before starting, because they are not equal:

```
item              damage                                       bar
_inFlightCalls    a drain completes INSTANTLY, reporting        CLEARED
                  success while cutting live calls off
wireStatusFor ->  a responder bypasses the default-deny gate    CLEARED, and
  sendError       and puts a foreign error on the wire          already drifted
_notify           a user callback kills the isolate             CLEARED
_startKeepalive   already drifted by one guard                  NARROW — see
                                                                Not fixed
```

## Hypothesis

Four extractions.

Three were. The fourth — `_startKeepalive` — turned out to be **two genuinely
different failure responses around one shared loop**, and extracting the whole
thing would have been the cosmetic unification RPC-25 declines.

## Before

```dart
// Both servers, byte-identical:
final metrics = endpoint.collectEndpointMetrics();
total += (metrics['activeResponders'] as int?) ?? 0;
```

`activeResponders` is an OBSERVABILITY key, sitting among a dozen others that
exist to be read by a dashboard. Rename it — or change its type, or nest it —
and both servers count ZERO, every drain completes instantly, and the shutdown
reports success.

`drainUntilIdle` was already shared. **The number feeding it was not**, and that
is the half deciding whether a shutdown waits at all.

## Mechanism

A map key is a contract nothing declares. The lead predicted this failure mode
exactly; what it could not predict is that **rounds 418 and 421 made it heavier
this session** — `RpcApp` now delegates shutdown to the server's drain, and
`stop()` keeps serving until the drain finishes.

## After

`RpcEndpointBase.activeResponderCount` — typed, so the compiler checks it,
declared on the base as 0 and overridden in the mixin (the shape `markDraining`
already uses, for the same reason). The metrics key now reads FROM it. Both
servers call `inFlightResponderCalls`, and `_notify` calls
`notifyWithoutDying`, both in core beside `drainUntilIdle`. Four responder sites
call `sendWireError`.

## Canary

One ablation, and its reading is the whole finding.

**Renaming the metrics key to `liveResponders`:**

```
the metrics-key test            FAILED   (it watches the coupling)
the websocket DRAIN test        PASSED   <- this is the point
```

Before this round that rename would have broken the drain **silently, with
every test green**. The drain is now independent of the key, and the only thing
that notices a rename is the test whose job is to notice.

## Gate

```
melos run analyze        SUCCESS, 21 packages + rpc_dart_wasm
melos run test:unit      SUCCESS
melos run format:check   SUCCESS
melos run license:check  compliant
melos run test:web       SUCCESS — dart2js
```

## Not fixed

**`_startKeepalive` is only half-extracted, on purpose.** What is shared —
`startHttp2Keepalive` — is the loop: the interval, the timeout, the
one-probe-at-a-time latch, and the `isDead` guard the server half LACKED. What
is not shared is the response, because the two differ deliberately: the caller
marks itself disconnected and discards the connection so calls fail fast and a
supervisor reconnects; the server destroys the socket, which fires `socket.done`
and runs the release wiring that disposes the contracts. Forcing those together
would be exactly what this lens declines.

**The server's missing guard was narrower than the lead implies.** Its release
wiring on `socket.done` does cancel the timer, so the window is "a stopped
server whose socket is still open" rather than "pings forever". Real, and
smaller than it reads.

**Nothing drives `startHttp2Keepalive` in a test of its own.** It is covered by
the existing keepalive suites on both halves staying green, which is a
regression argument rather than a measurement of the extraction.

**`sendWireError` has no witness either.** Four call sites, same behaviour
before and after; the existing error-routing suites cover the behaviour and
nothing covers "a fifth site cannot forget the gate", which is the actual
reason it exists.

**Filed while here: B-71** — a browser WebSocket client cannot detect a
half-open path at all. Found answering the owner's question about whether
websocket needs keepalive: it does not need a hand-rolled LOOP, because
`WebSocket.pingInterval` is native and closes the socket itself — but on the web
the browser owns ping/pong and the parameter is accepted and DROPPED, so that
one client has no liveness signal. Three shapes, none obviously right.

## Links

- B-63 — all six items now closed
- B-71 — filed here
- RPC-25 — and its own bar applied AGAINST a merge for the first time in a while
- rounds 418, 421 — made the drain count load-bearing, which is why this ranked
  first among the four
