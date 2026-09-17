---
round: 381
verdict: FIXED
packages: [rpc_dart, rpc_dart_websocket]
lens: RPC-23
bench: none — the owner's decision was doc-only; the measurement that justified it is round 354's, not re-taken here
commit: yes
---

# Round 381 — what `endpoints` promises

## Target

B-37, carrying out the owner's decision recorded after round 379: **leave the
getter, document what it means.** Second of the three the owner named, in order.

RPC-23: prose that leaves the next caller to guess. Here there was no prose at
all — `/// Active RPC endpoints.` over a getter that is empty in one of the two
modes the library ships.

## Hypothesis

n/a — the defect is established (round 354) and the decision is taken. This
round carries it out.

## Before

```dart
/// Active RPC endpoints.
List<RpcResponderEndpoint> get endpoints;
```

Two facts a caller cannot get from that, both load-bearing:

- the list is **empty in peer mode**, because each connection there is an
  `RpcPeerEndpoint` — a type that serves calls but is not an
  `RpcResponderEndpoint` and cannot appear in a `List<RpcResponderEndpoint>`;
- so an empty list means *none of this kind*, never *no connections*.

Round 354 measured the damage that reading cost: a graceful drain polled a
metric this getter's blind spot hid and shut the server down on top of live
calls. That defect is fixed and does not use this getter — what remained is the
promise nobody wrote down.

## Mechanism

n/a — no code defect remains. The gap was the documentation.

## After

`IRpcServer.endpoints` now says it lists responder endpoints only, that it is
empty in peer mode, and that an empty list is not a connection count. It also
records WHY the narrow type stays, so the next reader does not re-litigate it:
widening breaks every external implementor and hands callers something that may
not serve calls, and a second getter would leave this one quietly lying in one
mode.

`RpcWebSocketServer.endpoints` gets the same in one line, plus the fact that its
internal list holds both kinds — which is what `stop()` and the drain walk, and
is why the two disagree.

No signature moved.

## Canary

n/a — the change is prose, and a doc comment has no runtime to switch off.

What stands in for it: the claim is checkable from the types alone.
`RpcPeerEndpoint` is not an `RpcResponderEndpoint`, and the getter is
`whereType<RpcResponderEndpoint>()` over a list declared
`List<RpcEndpointBase>` — so "empty in peer mode" is not an observation that
could age, it is what the signature says.

## Gate

`melos run analyze` clean, `melos run test:unit --no-select` SUCCESS,
`melos run format:check` SUCCESS.

## Not fixed

**The asymmetry itself.** A caller in peer mode still has no supported way to
enumerate what is serving; it must reach for whatever the concrete server
exposes. That is the decision, not an omission — the alternatives break a
published interface or leave `endpoints` lying — and it is now written down
where a caller meets it rather than left to be discovered.

## Links

- RPC-23 — the lens; `applied:` gains 381
- B-37 — closed by this round
- Round 354 — measured the defect and left the API question open
- Round 375 — the same shape on `addClientStreamMethod`: a promise the API did
  not make, written down rather than changed
