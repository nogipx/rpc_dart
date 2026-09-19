---
round: 393
verdict: FIXED
packages: [rpc_dart]
lens: RPC-25
bench: P-82 — new
commit: yes
---

# Round 393 — two hundred listeners for one frame

## Target

B-57, the owner's U1. Both halves, and the scope was set before the fix: the
COST half (every live unary handler listens to the whole connection) and the
CORRECTNESS half (an advisory error answers calls that are still fine).

**And the fix direction B-57 recorded is wrong.** Round 392 filed "subscribe to
`getMessagesForStream(id)` instead" as strictly better. Reading the transport
before building on it says otherwise, and that correction is this round's first
product — see Mechanism.

## Hypothesis

Every frame on a connection costs one Future and one microtask per live unary
handler, and an advisory channel error fails calls that are not affected.

## Before

```
3000 frames pumped upstream, median of 5 runs
  parked unary handlers      1        50       200
  elapsed                   48 ms   126 ms   333 ms
```

Probe: `rpc_dart/.dart_tool/probe/unary_broadcast_fanout.dart` (P-82). N=1 is
the control: the fan-out cannot exist there, so a bench where that column moves
with the others is measuring the machine.

**The first version of this bench read a flat line — 36 / 22 / 31 ms — and it
was wrong.** Two counters planted in `UnaryResponder` said why: `3` listener
entries for a 3000-frame pump. It pumped with a SERVER-STREAM, and the parked
responders live on the server, whose broadcast carries only inbound frames. The
traffic never reached them. Pumped upstream through a client-stream instead, the
same counter reads **600 400 entries at 200 parked handlers** — exactly N per
frame, plus the call's own.

A flat line means "no defect" and "no mechanism" equally, and only the
instrument tells them apart (measurement.md item 8).

Advisory half, measured separately: an `IRpcAdvisoryChannelError` injected while
one call sits between its metadata and its data answers that call with a
trailer — `trailers: [1]`.

## Mechanism

`_setupRequestHandler` listens to `_transport.incomingMessages` — the whole
connection — with an `async` callback, and discards other streams' frames INSIDE
it. An `async` function allocates a Future whatever it does, so a frame nobody
wants still costs one Future and one microtask per live handler.

**Why B-57's recorded fix is wrong.** `getMessagesForStream(id)` creates a
per-stream controller (`channel_transport.dart:316-328`) and routing then takes
a different branch: `_admitToStreamBuffer` can refuse the frame and `return`
at line 885 — *before* the unconditional `_incoming.add(message)` at line 913.
So a unary request over the per-stream byte bound would be dropped from the
PIPELINE too, a bound that does not apply to unary today. It also moves unary
streams from credit-on-arrival to owed-until-consumed. Not a free swap.

The fix that costs nothing: make the callback SYNCHRONOUS and filter first.

## After

```
3000 frames pumped upstream, median of 5 runs
  parked unary handlers      1        50       200
  before                    48 ms   126 ms   333 ms
  after                     38 ms    42 ms    94 ms
```

**3.5x at 200 handlers, and the curve is nearly flat.** The control did not
move (38 against 48; across every run of this session N=1 read 36-61 ms, so its
spread covers that). The listener still runs N times per frame — that is what a
broadcast is — and what went is the allocation behind each.

Advisory half after: `trailers: []`.

## Canary

Two halves, two canaries.

**The advisory check** disabled (`if (false && error is ...)`):

```
WITNESS: an advisory error does not fail a waiting call
  Expected: empty
    Actual: [1]
  a discarded frame over a working connection answered the call with a trailer
```

Its GUARD — a real transport error must still answer — stayed green, so the
check does not take that path away.

**The cost half's canary is the measurement itself**: the same bench with the
old shape reads 333 ms against 94, on the same machine in the same session, with
an unmoved control. A hang or a throw it is not, so an ablation is the number.

## Gate

`melos run analyze` clean over 21 packages + wasm; `format:check` clean;
`license:check` compliant; workspace suite **SUCCESS in all 15 packages**,
rpc_dart **+1566 ~1** (was +1564; +2 from the advisory witness and its guard).

## Not fixed

**The fan-out COUNT.** 200 handlers still mean 200 listener invocations per
frame; only the cost of each is gone. Removing the count needs the subscription
itself to go, which is what B-57 was about and what the `getMessagesForStream`
route cannot safely do. B-57 stays open, now with the wrong answer struck out
and the measurement that says how much is left to win.

**The advisory window on the PIPELINE path is ~zero** and this round says so
rather than claiming a save it did not make: the pipeline feeds `handleMessage`
directly, where `_stateFor` and `requestHandled = true` sit in one synchronous
block (`responder.dart:351` and `368`). The reachable exposure is the low-level
API — a responder that sees a metadata frame over the wire and waits for the
data, which is where the witness puts it.

## Links

- RPC-25 — the lens; `applied:` gains 393
- P-82 — the bench, and the direction mistake it caught
- B-57 — the lead: cost half fixed, count half open, recorded fix corrected
- Round 392 — where B-57 was filed, including the fix direction this corrects
- L-15 — an instrument that cannot express the answer reports the wrong one;
  here the first bench could not reach the mechanism at all
