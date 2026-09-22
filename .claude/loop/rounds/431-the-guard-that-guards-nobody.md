---
round: 431
verdict: FIXED
packages: [rpc_dart_websocket]
lens: RPC-13
bench: none — B-39's own probe re-run unchanged, and what this round ADDED is a
  read of two construction sites rather than a number
commit: yes
---

# Round 431 — the guard that guards nobody

## Target

**B-39**, decided twice: zone-guard the sockets the library constructs, PLUS
document the residual for user-supplied ones. Reaffirmed by the owner after
round 426 when it was split from B-35.

This round ships the documentation half and **does not ship the guard**, because
measuring reachability first — which neither the lead nor either decision did —
says the guard protects nothing.

## Hypothesis

The decision rests on the guard buying something. The lead's own Reachability
section says what reaches the crash: *"an application holding the raw
`WebSocket` it passed to `RpcWebSocketChannel` and closing that directly while
a response is in flight."*

That is the USER-SUPPLIED socket. The guard covers the ones the LIBRARY builds.
If those two sets do not overlap, the decided fix and the reachable defect are
about different sockets.

## Before

The lead's probe re-run unchanged, 73 rounds later, reproducing exactly:

```
arm                                 isClosed   closeCode  send
live socket (control)               false      -          returned
our close() first (control)         true       -          returned
peer closed, same turn              false      -          returned
peer closed, +1 turn                false      -          returned
peer closed, +50ms (onDone in)      true       1005       returned
our raw socket, behind the channel  true       1006       returned
our raw socket, same turn, ZONED    false      -          returned, zone saw it
our raw socket, same turn           false      -          ROOT-ZONE CRASH
```

The defect is live and the construction-zone fix demonstrably works. Both
halves of the lead's measurement stand.

**What is new is the third question: can the crashing arm be reached with a
socket the library built?** Read at both construction sites:

```
RpcWebSocketCallerTransport.connect  ws_open_io.dart builds the raw WebSocket
                                     inside openWebSocket and wraps it; the
                                     socket is local and never handed out
the server's accept path             websocket_io_connections.dart:98 says it
                                     in its own comment -- "once inside
                                     IOWebSocketChannel the socket is no longer
                                     reachable"
```

**Nothing outside can close either one.** The only closer is the library, and
every library teardown path goes through `RpcWebSocketChannel.close()`, which
sets `_closed` FIRST — the "our close() first" control row, which returns.

So the crashing arm needs a raw socket the caller holds, and a caller only holds
one when it constructed the socket itself — in its own zone, which the decided
guard explicitly cannot reach.

## Mechanism

The guard and the defect are disjoint by construction:

```
who built the socket   raw socket reachable   crash reachable   guard helps
the library            no                     NO                nothing to help
the application        yes                    YES               cannot reach it
```

Not registered as a bench: the probe is the lead's and already valid there;
what this round added is a READ of two construction sites, not a new number.

## After

`RpcWebSocketChannel`'s class documentation now carries the residual where the
one caller who can hit it will read it — on the type they pass their own socket
to. It states the measured matrix, that neither `isClosed` nor `closeCode` can
see it, that a `try`/`catch` around the send does not help, and the two ways to
be safe: let [close] close the socket, or build it inside `runZonedGuarded`.

It also says that `RpcWebSocketCallerTransport.connect` and the server path
cannot reach this at all, which is the fact that makes the guard unnecessary and
the fact a reader most needs.

## Canary

None, and the reason is the finding: **there is no behaviour change to switch
off.** The evidence is the probe's matrix — unchanged before and after, because
this round changed no code — plus the two reads that say the crashing arm cannot
be built from a library-constructed socket.

The `ZONED` row is what a canary would have to demonstrate, and the probe
already carries it as a standing arm: remove the construction zone and that row
becomes the crashing one.

## Gate

```
melos run analyze        SUCCESS, 21 packages + rpc_dart_wasm
melos run test:unit      SUCCESS
melos run format:check   SUCCESS
melos run license:check  compliant, 1606/1606
rpc_dart_websocket       SUCCESS
```

## Not fixed

**The zone guard is NOT shipped, and this reverses half of a decision the owner
has now taken twice.** Stated plainly rather than buried: the decision was made
on the lead's framing, the lead never asked whether the guard's sockets are the
reachable ones, and they are not. Shipping it would reroute every async error
from every library-built channel — the trade the decision explicitly accepted —
in exchange for catching a throw that cannot occur there.

**This needs the owner's word before anything else happens on B-39.** Three
things they might reasonably say, and the round does not presume:

1. *Accept the measurement* — the documentation IS the fix, and B-39 closes.
2. *Ship the guard anyway* as defence in depth against a future path that hands
   the raw socket out; cheap to add, and the cost is the rerouting.
3. *Go upstream* — option (3) in the lead, still open: a sink that refuses an
   add should reject a future rather than throw into a foreign zone.

**The lead's status is left `decided by owner`, not closed**, because half of
its decision is deliberately unexecuted.

## Links

- B-39 — documentation half shipped; guard half refuted and returned to the
  owner
- B-35 — its sibling, left alone in round 426 for the same reason this round
  measured here: the trade is only worth paying against a path that exists.
  The two leads came apart on reachability, and this is the second time
- RPC-13 — an unhandled async error; the shape is real, the guard's aim was not
- L-13 — fifth round running where a decision's premise was the thing to check
