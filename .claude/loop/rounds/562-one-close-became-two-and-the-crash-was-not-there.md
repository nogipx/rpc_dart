---
round: 562
verdict: FIXED
packages: [rpc_dart_http2]
lens: RPC-21
bench: P-185 — new
budget: probes 1/5, canaries 1/5
commit: yes
release: changelog
---

# Round 562 — one close became two, and the crash was not there

## Target

B-192, next on round 559's class-A list, filed with confidence **high** and two claims:

1. the preface timeout releases the endpoint and then destroys the socket, whose `done` releases it
   again — so `onConnectionClosed` fires twice, with no idempotency guard;
2. `'${socket.remoteAddress}:${socket.remotePort}'` runs outside the try in the accept callback, and
   *"a peer that connects and resets immediately can end the server process"*.

Lens RPC-21: drive the lifecycle twice.

## Hypothesis

Both as filed. Claim 2 is the frightening one and the lead cites the class's OWN comment as support,
which is the kind of agreement rule one says to distrust.

## Before

```
one connection, preface deadline 100 ms
  silent, preface deadline    opened=1  closed=2      <- the defect
  speaks h2, closes politely  opened=1  closed=1      <- the control

200 x connect+RST            escaped=0   then a real call -> ok:x
200 x polite close           escaped=0   then a real call -> ok:x
```

Bench `../probes/P-185-two-paths-release-one-connection.md`.

**Claim 1 CONFIRMED**, with the polite close as the control: without it a count of 1 could mean the
callback had simply stopped firing.

**Claim 2 REFUTED.** 200 connect-and-reset cycles put nothing into the zone and the server answered a
real call afterwards — which is the arm that matters, because "still running" is a flag an isolate
about to die still reports.

## Mechanism

Claim 1 is one line: `_endpoints` is the registry of live connections, so the second caller finds
nothing to remove. `if (!_endpoints.remove(endpoint)) return;` makes the whole release idempotent —
the endpoint close, the connection-map removal and the callback.

**Claim 2 is where the lead went wrong, and it did so by quoting the code correctly.** The comment it
cites says reading `remotePort` throws *"ON CLOSE ... because the peer is already gone"*, and the
accept-path read happens on a socket just accepted and not closed. Those are different states, and the
positive control separates them:

```
just accepted             127.0.0.1:63895
peer reset, still open    127.0.0.1:63895
after our own destroy()   THREW SocketException: Socket has been closed
```

The read throws after **our own** `destroy()` — on the close path, which is exactly where
`notifyWithoutDying` already wraps the callbacks. A peer resetting does not put the socket in that
state; only closing our end does, and the accept path cannot have done that yet.

## After

```
  silent, preface deadline    opened=1  closed=1
  speaks h2, closes politely  opened=1  closed=1
```

## Canary

```
the guard removed (`_endpoints.remove(endpoint)` without the early return)

WITNESS a preface-deadline close reports it ONCE
  Expected: <1>
    Actual: <2>
  the deadline releases the endpoint and destroys the socket, whose `done`
  released it again
```

**Claim 2 needed a positive control rather than a canary**, since there was nothing to switch off. Two
clean rows mean "the accept path is safe" or "this rig never produced the failing state", and the
address read in three states is what separates them. Round 557 is the precedent: a first probe there
had no working control and would have reported safety on a rig that could not have shown otherwise.

## Gate

```
melos run analyze               SUCCESS   21 packages + rpc_dart_wasm
melos run test:unit --no-select SUCCESS   15 packages
melos run format:check          SUCCESS   0 changed
melos run license:check         SUCCESS   REUSE compliant
```

## Not fixed

**Four of B-192's six items are untouched** and the lead stays open: `stop()` closing endpoints
serially (N x up to 2 s — a cost, and `Future.wait` is the sketch), `start()` not being re-entrant
(which round 560 fixed for the double-start race, so what remains here is a different reading of the
same method and may be a duplicate), `createWithContracts` dropping the ping and preface options, and
the *"nothing has subscribed yet"* comment the lead calls probably false.

**The reset loop is 200 cycles on one platform.** A refutation from a loop is weaker than one from a
state: the address rows are what carry it, and they say the throwing state is unreachable from the
accept path rather than unlikely.

**`onConnectionOpened` was not double-fired in any arm**, so the guard is witnessed on the close half
only. `opened=1` in every row is the evidence that it was never the problem.

## Links

Lead `../backlog/B-192-http2-server-double-close-and-accept-crash.md` — claim 1 fixed, claim 2
refuted, four items open.
Bench `../probes/P-185-two-paths-release-one-connection.md` — new.
Round `557-the-comment-named-a-zone-that-was-not-there.md` — the same shape of error in the same
package: a true warning attached to the wrong call.
Negative `../checked/C-61-the-audit-intake-sorted-by-who-it-hurts.md` — the grading that put this lead
in class A.
Lens `../lenses/RPC-21-drive-the-lifecycle-twice.md` — `applied: [562]`.
