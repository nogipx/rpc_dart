---
round: 479
verdict: FIXED
packages: [rpc_dart, rpc_dart_websocket]
lens: RPC-07
bench: P-120 — new
commit: yes
---

# Round 479 — only silence is death

Three benches, though the header names only the one the format admits: **P-120**
(new, the defect), **P-116** (reused, round 466's measurement of the gap itself)
and **P-121** (new, the sibling sweep).

## Target

B-71, the last owner decision with work in it: *"Option 3, opt-in: an
application-level heartbeat on the EXISTING ping, web only, off by default.
Carry it on `RpcEndpointPingExchange`, which the lead already names."*

The decision also carried an item it called "unresolved and part of the round,
not a blocker" — *"a heartbeat firing while a long call is in flight competes
with it for the connection window. Measure that before choosing the default
interval."* That is where the round turned.

## Hypothesis

Round 466 measured the gap (P-116) and it is total, not merely slow:

```
ws_open_io   (dart:io, honours pingInterval)   626ms to notice
ws_open_stub (web, DROPS pingInterval)         NEVER (capped at 5s)
CONTROL: ws_open_io, no interval               NEVER
```

So the web arm needs its own probe. The library already has one —
`RpcEndpointPingExchange` — and any rpc_dart responder answers it, so no new
wire vocabulary is needed.

## Mechanism

A per-platform const beside each `openWebSocket`
(`platformHonoursPingInterval`: true on dart:io, false on the stub) lets the
transport ask whether the platform already did this. Where it did not, a
`Timer.periodic` at the SAME `pingInterval` runs the exchange with a one-interval
timeout, and answers a dead peer the way dart:io does — by closing the socket.
One probe at a time, cancelled on `close()`, re-armed after a reconnect.

`platformHandlesPing` overrides the const so the web behaviour is reachable from
a VM test: the stub is the portable fallback as well as the web implementation,
but the constant selecting them is a conditional import and cannot be varied at
runtime.

Three ping symbols came out of `rpc_dart.dart`'s `hide` list to make this
expressible by a transport outside core.

## Before

Then the owner's open item, measured rather than reasoned (P-120). Reading moved
the question first: the ping sends only `sendMetadata`, and `sendMetadata` never
consults flow-control credit — only `sendMessage` does. So the connection WINDOW
is not where a heartbeat and a long call meet. `createStream()` is: it THROWS
`resourceExhausted` at `maxActiveStreams`, and the heartbeat's catch-all read
every throw as a dead peer.

Against a LIVE responder, interval 200 ms:

```
B  at the ceiling (4 of 4 streams held)   CLOSED (false positive)
B* CONTROL: one id free (3 of 4 held)     open
C  under a 120000 x 1 KiB stream          open  (120000 msgs in 4720ms)
```

Arm C is the owner's question in its literal form, and it is clean. Arm B is the
same question on the axis nobody named: **the fix as first written killed a
healthy connection, and took down the very calls that filled the ceiling.**
Worse than the silence B-71 set out to fix.

## After

The catch discriminates. `TimeoutException` — nothing came back within one
interval — closes. Everything else leaves the connection alone and retries next
interval, because a probe that could not be SENT, or one the peer ANSWERED with
an error, is not evidence of a dead path.

```
B  at the ceiling (4 of 4 streams held)   open
B* CONTROL: one id free (3 of 4 held)     open
C  under a 120000 x 1 KiB stream          open  (120000 msgs in 5561ms)
```

Detection is unchanged: the witness still closes on a genuinely silent peer.

## Canary

Two, each failing a different test and leaving the others green.

1. **Heartbeat removed** — the witness fails with `Expected: not null / Actual:
   <null>`: *"the heartbeat never fired or never gave up, so a web client on a
   half-open path is back to waiting out a deadline that is optional on this
   transport"*.
2. **The catch-all restored** — only the ceiling test fails, `Expected: null /
   Actual: <206>`. 206 ms is one interval: the first probe that could not mint an
   id closed the connection.

Canary 2 is the one that matters, because it is the defect this round nearly
shipped.

## Sweep

`startHttp2Keepalive` is the same loop with the same `catch (error) { …
onDead(error) }`, and http2 enforces the same ceiling in its own `createStream`
(`rpc_http2_caller_transport.dart:727`). Reading says it cannot bite there — the
probe is `connection.ping`, a protocol-level PING frame charged to no stream
limit — but that is an argument, so P-121 measured it:

```
4 of 4 streams held                  ready
3 of 4 streams held                  ready
0 of 4 held, path FROZEN             DOWN (correct: the path IS dead)
```

The frozen arm is not decoration. Two arms reading `ready` are equally
consistent with a keepalive that never fired inside the window — a void arm
reads exactly like a clean one (L-15). It fires, and it reports; the ceiling
does not reach it. **http2 is clean, measured.**

## Prose that had gone false

The same commit, per rule one: the transport's `connect` doc still carried
`websocket (web)  NOTHING` in its detection table, and `ws_open_stub`'s still
said a web client "has no liveness signal at all". Both were true when written
and are now the opposite.

## Gate

`melos run analyze` SUCCESS, `format:check` SUCCESS, `license:check` SUCCESS,
`test:unit --no-select` SUCCESS over 15 packages. `rpc_dart_websocket` 191 -> 192
tests.

## The second promise round 466 sized, and why it was not made

Round 466 priced this fix at **two** new public promises in core: the three ping
symbols un-hidden, and `startHttp2Keepalive` lifted out of `rpc_dart_http2` so
both transports share one loop. Only the first was made.

The owner's decision granted the ping symbols and said nothing about the lift,
and round 466 itself is why that silence is binding: *"RPC-24: a shared helper
is chosen, not emitted. That is an owner call, not a round's."*

It also turned out to be the right shape on the merits. The two loops differ in
exactly the thing this round fixed: http2's probe opens no stream and cannot be
refused, so "any throw means dead" holds there (P-121); the websocket probe
opens one and can be refused, so it must discriminate. Sharing the loop would
mean parameterising *what counts as death* — which is the entire content of the
fix, hoisted into a core API to be passed back down. `rpc_http2_common.dart`
already declines the neighbouring version of this: *"What is shared is the loop,
not the response … forcing those together would be the cosmetic unification
RPC-25 declines."*

## Not fixed

**The default interval stays null (off).** The owner's decision says off unless
asked for, and the measurement that was supposed to inform a default instead
found a defect on another axis; nothing here argues for turning it on. A caller
that wants it passes `pingInterval`, which now means the same thing on both
platforms.

**A peer that answers `unimplemented`** — one without the ping handler
registered — is now probed every interval forever, each probe answered and
discarded. Correct (it is alive, and it is not closed), but it is wire cost with
no ceiling on it. Not reached by any transport in this repo, whose responders all
register the handler. Worth a warn-once if a real deployment meets it.

## The verdict check

Q1 — the control is arm B with ONE stream id free; same peer, interval, wait and
code path. Q2 — before the fix B read `CLOSED` and B\* `open`, so the bench sees
the defect. Q3 — `transport.isClosed` and `health()`, both the library's own
state, not the harness's. Q4 — the `open` readings are protected: B's own
before-state closed inside the same window, and P-121's frozen arm reports
`down` inside it. Q5 — real messages, both quoted above; neither is a timeout.
Q6 — two halves, two canaries, each failing a different test. Q7 — FIXED follows
from `CLOSED -> open` with detection unchanged.

A1 — no attacker/victim split to make: the defect is self-inflicted, the
transport closing itself. A2 — the half-open gap is LATENCY and the bench
introduces it with a real socket to a silent peer; arm B's gap is a RESOURCE
ceiling, constructed by arithmetic and needing no socket. L1 — the refusal under
test is named by the boundary: arm B mints exactly `maxActiveStreams` ids
without throwing, so the throw the heartbeat meets is that limit and not a
neighbouring one; B\* at one fewer id does not produce it.

## Links

- RPC-07 — web as a separate runtime: closing a platform gap puts the OTHER
  platform's assumptions in play
- U-02 — attack your own fix. Instantiated INSIDE the round rather than the next
  one, because the decision's open item pointed at it
- L-13 (third half, written here) — a decision's sentence can be right and still
  bound the measurement too tightly
- L-15 — a void arm reads like a clean one; it is why P-121 has a frozen arm
- L-12 — sweep the class: the sibling loop was found by grepping the shape, not
  by remembering it
- B-71, P-116 (round 466, the gap), P-120, P-121
