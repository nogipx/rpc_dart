---
round: 465
verdict: CLEAN
packages: [rpc_dart, rpc_dart_websocket, rpc_dart_http2]
lens: RPC-25
bench: P-115 — new
commit: yes
---

# Round 465 — three mechanisms, one outcome

## Target

B-76's last half, and the last lead in the backlog that is not waiting on a
device, a service or the owner. Round 464 closed step 2; what stayed open is the
lead's original body: three machines solving stream-id reuse three ways.

## Hypothesis

There is no defect here. Rounds 449 and 451 both ended the same way on this same
lead — the divergence is real and the harm is not — and nothing in the lead ever
measured an id coming back.

Stated as a hypothesis on purpose: it is the one a round is most likely to
confirm by not looking hard enough, so the bench's control matters more than its
arms.

## Before

One call left OPEN across one reconnect, then the operation the lead's own body
names as the cost — a late `finishSending` from the dead call, which presents
nothing but the id:

```
             before  after  collision  late finishSending
websocket      1       3       no      no -- different id
http2          1       3       no      no -- different id
proxy          1       3       no      no -- different id
```

## Control

`_nextStreamId = 1` restored in http2's reconnect, which is the reset its own
comment says is deliberately absent:

```
http2          1       1      YES      YES -- same id
```

The bench sees the collision and its consequence. A clean row is therefore about
the code.

**The control found the round's one new fact.** With http2's counter reset, the
PROXY arm — built on that same transport — still read `1 / 3 / no`. Its
`_idWatermark` carries the sequence across a transport that rewinds its own,
which its doc comment claims and nothing had ever exercised. The ablation was
aimed at one machine and answered a question about another.

## Why they must NOT be merged

The `## Ask` again, and this time it has a clean answer — round 451's rule, that
a duty lands where its resources are:

```
websocket   keeps its transport object, must REJECT ids from a dead connection
http2       keeps its transport object, need only not rewind a counter
the proxy   REPLACES the transport, so the sequence must cross an object boundary
```

The third cannot use either of the first two: the object holding the counter is
gone by the time it needs the value. One shared class here would be one class
with three flags, which is what RPC-25's "What NOT to merge" exists to refuse.

## Mechanism

None — no code changed. What the round establishes instead is why each of the
three mechanisms is the right one for its own machine; that is the "Why they must
NOT be merged" section below, and it is this round's deliverable.

## After

Unchanged, and that is the result. Nothing in `lib/` was touched, so the table
above is both the before and the after — the round's output is the negative and
the reason the three must stay three.

## Canary

None, and the reason is the verdict: nothing was fixed, so there is nothing to
switch off. **The control above IS this round's variation** — `_nextStreamId = 1`
restored in http2 turns two columns red on command, which is what Q2 asks for and
what makes three clean rows evidence rather than an absence.

## Gate

`melos run analyze` SUCCESS, `format:check` SUCCESS, `license:check` SUCCESS,
`test:unit --no-select` SUCCESS across all 14 packages. **No source changed**, so
the gate confirms the control was restored rather than left in — which is the
only thing it can fail on in a round like this, and the failure it would catch is
a live defect planted by the round itself.

## Not fixed

**Nothing, deliberately.** The verdict is CLEAN: there is nothing here to fix,
the negative is `checked/C-53`, and B-76 closes with it.

What is NOT covered by the measurement, and would need its own round if anybody
wants it: several concurrent calls across one reconnect, repeated reconnects, and
an id released and re-minted within a single connection. The arms are unary.

## Links

- RPC-25 — "What a no-drift candidate earns: nothing", and "What NOT to merge"
- Round 451 — ask which layer OWNS the thing the duty needs; the pair the
  detector shows you may be the wrong pair
- Round 449 — a divergence is a lead about where to look, never a finding about
  what happens. Third time on this same lead
- P-115, C-53, B-76
