---
round: 466
verdict: DEFERRED
packages: [rpc_dart_websocket]
lens: RPC-07
bench: P-116 — new
commit: yes
severity: S1
---

# Round 466 — the gap measured, and two public promises priced

## Target

B-71, the last decided lead that needs neither a device nor a service nor an
outward-facing action. The owner took **option 3, opt-in: an application-level
heartbeat on the existing ping, web only, off by default**, and attached two
preconditions: check first whether `pingInterval` on the web arm can DRIVE it,
and *"unresolved and part of the round, not a blocker"* — measure what a
heartbeat costs a call in flight before choosing the interval.

**Scope, stated up front: the two preconditions, not the heartbeat.** The reason
is in `## Not fixed` and it is a pair of public-API decisions that belong to the
owner. Saying so here rather than at the end is the rule L-12 exists for.

## Hypothesis

The lead has no bench (`probe: none — READ`) and claims a web client has *"no
liveness signal at all"*. "None" and "slower" are different leads and would take
different fixes, so the first thing to establish is which one it is.

## Before

P-116. The stub `openWebSocket` is the portable fallback as well as the web one,
so both arms run on the VM against one raw server that completes the handshake
and then answers nothing — pings included, which a `dart:io` WebSocket server
would not do.

```
a silent peer, pingInterval = 300ms, cap 5s
  ws_open_io   (dart:io, honours it)     626ms      ~2 intervals
  ws_open_stub (web, DROPS it)           NEVER (capped)
  CONTROL: ws_open_io, no interval       NEVER (capped)
```

The claim holds, and now has a number: detection at about twice the interval
where the parameter bites, none at all where it is dropped. The control is what
makes it a statement about the INTERVAL rather than about `dart:io`.

## Precondition one — can `pingInterval` drive it? Yes, and it costs two promises

`RpcEndpointPingExchange` takes an `IRpcTransport` and a `streamId` and nothing
else, so a TRANSPORT can drive one over itself — the same shape as http2's
`startHttp2Keepalive`. The answer to the owner's question is yes.

What it costs is the part worth bringing back:

```
RpcEndpointPingExchange   HIDDEN from rpc_dart.dart's export, with
RpcEndpointPingProtocol   and RpcEndpointPingResult
startHttp2Keepalive       package-private to rpc_dart_http2
```

So the websocket transport can reach neither the ping nor the loop. Two new
public promises in core are needed — un-hiding the three ping symbols, and
lifting the keepalive loop out of http2 — and RPC-24's rule is that a shared
helper is CHOSEN, not emitted. The owner's decision authorises a heartbeat; it
does not authorise those.

The loop is the cleaner of the two: `startHttp2Keepalive` takes `interval`,
`timeout`, `ping`, `isDead`, `onDead` and is entirely transport-agnostic. Its own
doc already calls it *"the PING-keepalive loop both HTTP/2 halves run"* — a third
caller in another package is exactly RPC-25's case for moving it beside the
siblings' shared dependency.

## Precondition two — what it costs: INCONCLUSIVE, and the reason is the bench

```
120000 x 1 KiB            run 1     run 2    pings landed
no heartbeat              4380ms    4806ms
ping every 300ms          4741ms    5492ms    15 / 18
ping every 50ms           4124ms    4764ms    77 / 86
no heartbeat              4096ms    4558ms
```

**Not a cost measurement.** The 300 ms arm is slowest in both runs while carrying
a fifth of the other's pings, which is incoherent as a dose-response and is the
fixed arm ORDER showing through. What the bench does support: the effect is
smaller than the ~7% spread between the two identical no-heartbeat arms, and
there is no dose-response at 5x the ping rate.

The first version of this half was VOID and said "free": at 2000 messages the
stream finished in ~100 ms and **zero pings landed in either heartbeat arm**.
The ping COUNT is what caught it — L-15, and the reason the count is printed.

## Mechanism

None. No code changed.

## After

Unchanged. The round's output is the number the lead never had, the answer to
precondition one with its price, and an honest INCONCLUSIVE on precondition two.

## Canary

None — nothing was fixed. The variation the round has is the control arm
(`ws_open_io` with no interval), which turns the detecting arm into a
non-detecting one on command and is what makes `NEVER` evidence rather than an
absence.

## Gate

`melos run analyze` SUCCESS, `format:check` SUCCESS, `license:check` SUCCESS,
`test:unit --no-select` SUCCESS across all 14 packages. No source changed.

## Not fixed

**The heartbeat itself.** Two reasons, and neither is "it was hard":

1. It needs two new public promises in core — the three ping symbols un-hidden,
   and the keepalive loop lifted out of `rpc_dart_http2`. RPC-24: a shared helper
   is a public promise and is chosen, not emitted. The owner decided a heartbeat,
   not a widening of core's surface, and these are the kind of decision that is
   expensive to reverse.
2. The owner's own second precondition is not resolved. The interval was to be
   chosen after measuring the cost, and the cost came back INCONCLUSIVE for a
   reason in the bench rather than in the code.

**What a next round would take, already sized**: lift the loop into core (one
function, five parameters, two existing callers to repoint), un-hide the three
ping symbols, then the web arm reports whether it honoured `pingInterval` and the
transport runs the loop when it did not. That last shape is what makes it
testable on the VM without a browser, which is why it is worth stating now.

## Links

- RPC-24 — a shared helper is a new public promise, chosen rather than emitted
- RPC-25 — `startHttp2Keepalive` is a loop with two callers in one package and a
  third wanting it in another, which is the case for moving it to core
- L-15 — the cost half was VOID first and read as "free"; the ping count is what
  said so
- P-116, B-71
