---
round: 279
verdict: FIXED
packages: [rpc_dart]
lens: RPC-17
bench: P-29 — new
commit: yes
---

# Round 279 — a header weighs more than its characters

## Target

**Round 278's own leftover, which round 278 dismissed in prose instead of
measuring.** Its battery showed the codec bounds metadata by BYTES and by
nothing else — 4000 headers fit inside the 64 KiB cap — and its record said
"bounded and caught, so recorded rather than pursued". That was reasoning, not a
number, on a round whose whole method is the opposite. The owner pushed back on
the session stopping, which is what sent me back to it.

RPC-17's dimension clause: *a bound whose units are not the units of the damage
is not a bound.*

## Hypothesis

`RpcTransportMessage.bufferedBytes` weighs metadata as
`h.name.length + h.value.length`. That is a CHARACTER COUNT. A header is an
`RpcHeader` object plus two Strings, so `["h1","v1"]` weighs 4 and retains
around a hundred bytes — and the queue's byte bound is computed from the former.

## Before

P-21's control repeated first, then the arm P-21 does not have: many tiny
headers instead of eight large ones. One arm per process, `maxRss`.

```
arm      headers  admitted   wire  weighed     RSS  ratio  stopped by
payload        -       256   16.0     16.0    37.3   2.3x  the byte bound
thin         500      4096   30.4     14.8   190.8  12.9x  the EVENT count
thin        2000       943   30.4     16.0   186.4  11.7x  the byte bound
thin        5000       351   29.4     16.0   186.3  11.6x  the byte bound
```

Probe: `packages/core/rpc_dart/.dart_tool/probe/metadata_weighs_characters.dart`

**A plateau at ~186 MiB against a 16 MiB bound, at every scale** — retention,
not churn — while the payload arm, weighed correctly, sits at 2.3x. Roughly 100
bytes retained per header, weighed as 8.

The sharpest row is `thin 500`: the byte bound **did not engage at all**. The
event count stopped it, which is exactly the hole round 236 closed for payloads,
reopened one dimension over. 500 headers per frame is not a coincidence — it is
the attacker's optimum, where weighed-per-frame stays under the bound right up
to the 4096-event ceiling.

## Mechanism

Round 245 fixed metadata weighing ZERO. What it then weighed was the text, and
the text is the one thing about a header that is not its cost. The peer picks
the shape, and the cheap shape for the peer is the expensive shape for the
queue.

## After

`bufferedBytes` charges `_perHeaderOverheadBytes = 64` per entry on top of its
characters — under the measured 97/103/111 deliberately, as a floor that holds
if a runtime lays objects out differently.

```
thin         500       468    3.5     16.0    20.8   1.3x  the byte bound
fat            -       253   15.8     15.9    21.8   1.4x  the byte bound
payload        -       256   16.0     16.0    39.9   2.5x  the byte bound
```

190.8 -> 20.8 MiB, and the BYTE bound is what stops it now. The fat arm moves
255 -> 253 and the payload arm not at all: the charge is a correction, not a
re-pricing.

## Canary

`test/core/metadata_weighs_more_than_characters_test.dart` — with the charge
removed, both witnesses failed with real numbers:

    Expected: a value greater than <16000>
      Actual: <3780>
    each header must carry a per-entry charge, not just its text

    Expected: a value less than <4096>
      Actual: <4096>
    the byte bound must engage before the event ceiling

while both GUARDs passed. RSS is deliberately not what the test asserts on — it
went negative with `currentRss` — so the observable is what the queue admits.

## Gate

`melos run analyze` (21 packages + wasm), `melos run test:unit --no-select`,
`melos run format:check`, `melos run license:check` — all green.

One existing test had to change and it is worth stating plainly, because
"loosened a test to fit" is exactly what a round may not do. Round 245's
`the two dimensions agree within a frame of each other` asserted
`(metadata - payload).abs() <= 2`; the charge moves the fat frame by 3. That
assertion passed in BOTH directions, including the one the file exists to
prevent — metadata weighing less than the payload it stands in for. It is now
directional (`metadata <= payload`) with a proportional tolerance, which is
strictly stronger, and the reason is in the test.

## Not fixed

64 is a floor, not the measured 97-111. Charging the true figure would bound
harder; charging a floor is what survives a runtime with a different object
layout, and dart2js is a real target here. The gap is stated in the constant's
doc comment.

## Links

RPC-17 (`applied:` gains 279) — its dimension clause, for the third time:
round 236 found a queue counting EVENTS while the damage was bytes, round 245
found metadata weighing ZERO, and this found it weighing the wrong bytes. Bench
P-29, extending P-21. Round 278 is where the lead came from, and the record of
that round is corrected to say so.
