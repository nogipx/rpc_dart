---
status: decided by owner (round 445)
round: 422
commit: 5674789e
paths: [packages/transport/rpc_dart_websocket/lib/src/websocket_caller_transport.dart, packages/transport/rpc_dart_websocket/lib/src/ws_open_stub.dart]
probe: none — READ, found while answering "does websocket need keepalive?"
reason: risk — the WebSocket API in a browser has no ping, so the fix is an application-level heartbeat with its own wire cost, and the owner has not asked for one
---

# B-71 — a browser WebSocket client cannot detect a half-open path

## MEASURED (round 466). Both preconditions answered; the fix needs TWO owner calls.

The claim was filed from a read and now has a number. Both `openWebSocket`
implementations run on the VM — the stub IS the portable fallback as well as the
web one — against a raw server that completes the handshake and then answers
nothing, pings included:

```
pingInterval = 300ms, cap 5s
  ws_open_io   (honours it)          626ms     ~2 intervals
  ws_open_stub (web, DROPS it)       NEVER
  CONTROL: ws_open_io, no interval   NEVER
```

**Precondition one — can `pingInterval` drive it? YES**, and here is the price.
`RpcEndpointPingExchange` takes only an `IRpcTransport` and a `streamId`, so a
transport can drive one over itself. But it, `RpcEndpointPingProtocol` and
`RpcEndpointPingResult` are all HIDDEN from `rpc_dart.dart`'s export, and
`startHttp2Keepalive` is package-private to `rpc_dart_http2`. So the fix needs
**two new public promises in core** — the three ping symbols un-hidden, and the
keepalive loop lifted out of http2. RPC-24: a shared helper is chosen, not
emitted. That is an owner call, not a round's.

**Precondition two — the cost: INCONCLUSIVE.** 120000 x 1 KiB with pings at
heartbeat rate: the 300 ms arm is slowest in both runs while carrying a fifth of
the 50 ms arm's pings, which is arm ORDER rather than ping load. Bound: smaller
than the 7% spread between two identical control arms, no dose-response at 5x the
rate. Needs interleaved arms to resolve. (The first version read "free" with ZERO
pings landed — the stream finished before the first tick.)

**Sized, for whoever takes it**: lift the loop into core (one function, five
parameters, two callers to repoint), un-hide the three ping symbols, then have the
web arm REPORT whether it honoured `pingInterval` and the transport run the loop
when it did not — which is what makes the whole thing testable on the VM without
a browser.

`../rounds/466-the-gap-measured-and-two-promises-priced.md`,
`../probes/P-116-how-long-until-a-web-client-notices.md`.

WebSocket keepalive is native: `dart:io`'s `WebSocket.pingInterval` pings every
interval and CLOSES the socket itself if no pong returns in one. That is why
there is no hand-rolled loop on this transport, and why round 422's
`startHttp2Keepalive` is http2-local — HTTP/2 needs the loop because
`package:http2` exposes `ping()` and does not act on a missing ACK.

On the web there is no equivalent. The browser owns ping/pong and exposes
neither, so the parameter is accepted and DROPPED. The code already says so, at
`websocket_caller_transport.dart:123`:

> *"Accepted and IGNORED on the web: browsers run ping/pong inside the browser"*

and `ws_open_stub.dart:34` takes `pingInterval` only for signature parity.

## What that costs

A browser client on a half-open path — the peer gone, the socket still "open"
to the runtime — has **no liveness signal at all**. It learns only when a call
reaches its own deadline, and a caller that set none waits forever. Every other
transport detects this:

```
  transport            half-open detected by
  websocket (VM)       WebSocket.pingInterval, native
  websocket (web)      NOTHING
  http2                startHttp2Keepalive, this library's own loop
  isolate              the port closing
```

The asymmetry is invisible from the API: the same
`RpcWebSocketCallerTransport.connect(..., pingInterval: ...)` call silently does
one thing on the VM and nothing in a browser.

## Why it is filed rather than fixed

The only route is an application-level heartbeat — an RPC the client sends on a
timer — and that is a design decision with costs the owner has not been asked
about:

- it puts traffic on the wire that the VM path does not need, so the two
  platforms stop behaving the same in the other direction;
- `RpcEndpointPingExchange` already exists and could carry it, but nothing
  currently drives it on a schedule;
- a heartbeat that fires while a long call is in flight competes with it for
  the connection window.

Round 224's rule applies: a capability a transport cannot provide should be
refused at the type level rather than accepted and ignored. The narrow version
of this fix is to make the web path REFUSE a non-null `pingInterval` instead of
dropping it, so the gap is at least loud — that is a one-line change and a
breaking one for anyone passing it today.

## Round 442 — the shipped docs said the OPPOSITE of this record

The owner asked for a witness. There is none to build (see below), but looking
for one found that **this lead's central claim was contradicted in writing, in
the two places a reader looks.**

```
this record        "no liveness signal at all"        measured, round 422
the API doc        "A web client is not unprotected"  shipped
the stub           "is not left unprotected --
                    the browser is doing it"          shipped
```

Both doc copies are false. A browser does run ping/pong, which is what the
reassurance rests on, but it exposes neither the interval nor the OUTCOME: a
missing pong never reaches the page and does not close the socket the way
`dart:io` does. True of the frames, false of the only thing the frames are for.
And two copies that agree read as corroboration, which is how it survived.

Both now carry this record's table and the consequence neither had: **on the
web, set a deadline on every call — it is the only bound there is.** One code
change, `pingInterval` added to the stub's discard tuple, whose own comment says
that tuple exists so a reader sees the platform cannot honour them.

**That was option 1 below, and it is now spent.** The gap is unchanged; it is
merely honest.

### Why the witness cannot be built — do not re-attempt

Half-open means the peer is gone with no FIN and no RST, which needs raw socket
control AFTER the handshake:

- `dart:io`'s `WebSocket` answers ping at the protocol layer, so a server on
  `WebSocketTransformer.upgrade` cannot be made to go silent;
- hand-rolling the upgrade on a raw `ServerSocket` needs the
  `Sec-WebSocket-Accept` SHA-1, and this package depends only on
  `web_socket_channel`;
- the web arm needs a browser cuttable at the network layer, and `test:web` is
  dart2js against node.

## Owner decision

**Option 3, opt-in: an application-level heartbeat on the EXISTING ping, web
only, off by default.** Minor, not a break.

- Carry it on `RpcEndpointPingExchange`, which the lead already names. No new
  frame type and no new wire vocabulary — the only new thing is a timer driving
  what exists.
- Off unless asked for. The shape to check first is whether `pingInterval` on
  the web arm can DRIVE this instead of being dropped: that makes the parameter
  mean the same thing on both platforms, and it resolves option 2's complaint
  without option 2's break. If that does not work out, an explicit separate knob
  is the fallback — do not reach for refusing `pingInterval`.

DECLINED: always-on (`dart:io` already does this at the platform layer, so four
transports would pay the wire cost for one's need), and an idle-activity
callback alone (without a probe, quiet is indistinguishable from dead — it is a
building block, not detection).

Unresolved and part of the round, not a blocker: the lead's third bullet — a
heartbeat firing while a long call is in flight competes with it for the
connection window. Measure that before choosing the default interval.

Option 1 was spent by round 442. The three shapes it was chosen among:

1. **Leave it, document it.** The comment exists; the transport's public doc
   does not say it.
2. **Refuse it loudly** on the web path, so the silent drop becomes an error.
   Breaking for callers that pass `pingInterval` and run on both platforms.
3. **An application-level heartbeat** driven by the caller transport, web only,
   with the wire cost above.
