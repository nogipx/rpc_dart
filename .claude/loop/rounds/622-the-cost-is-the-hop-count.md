---
round: 622
verdict: CLEAN
packages: [rpc_dart]
lens: RPC-15
bench: P-224 — new
budget: probes 3/5, canaries 0/5
commit: yes
release: none
---

# Round 622 — the cost is the hop count

## Target

B-204: about 4.4 us per streamed message in the bridge stack under the
endpoints, none of its layers varied. The lead asked for an attribution before
any layer was collapsed.

## Hypothesis

One layer of the stack holds most of the cost and can be thinned without
touching the bridges that exist for dart2js.

## Before

```
P-147 at HEAD (endpoints)          min 4.351  median 4.439 us/message
floor (transport+framing+codec)    min 1.567  median 1.571 us/message

top frame: dart:async 58.3 % (with -patch)   rpc_dart 23.7 %   hash maps 6.8 %
```

`P-224`. The endpoints cost about 2.8 us per message over the floor, 64 % of a
message.

## Control

The floor arm, which keeps the transport, the framing and the codec and removes
the endpoints.

## Mechanism

REFUTED: no one layer holds it. Nearly 60 % of the time has a `dart:async`
frame on top: microtask dispatch, `_sendData`, future propagation. rpc_dart's
own code is under a quarter. The cost is the number of asynchronous hops a
message makes through the processors, bridges and controllers, about one
microtask each. Shrinking it means collapsing those layers, and they exist
because `async*` cancellation behaves differently under dart2js. The owner
closed the lead on this attribution (2026-10-02): restructuring the bridges is
a separate piece of work, not a defect. 2.8 us shows only on an in-memory
transport with tiny messages.

## After

n/a — no change.

## Canary

n/a — no fix.

## Gate

Not run: no change to `lib/` or `test/`.

## Not fixed

The hop count itself, by the owner's decision.

## Links

Lead `../backlog/B-204-the-bridge-stack-under-every-streaming-message.md` — closed.
Bench `../probes/P-224-where-a-streamed-message-goes.md` — new.
Lens `../lenses/RPC-15-remeasure-own-record.md` — `applied: [..., 622]`.
