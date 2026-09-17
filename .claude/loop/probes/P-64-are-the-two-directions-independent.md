---
file: packages/core/rpc_dart/.dart_tool/probe/bidi_duplex_semantics.dart
round: 373
commit: 21f3525c
paths: [packages/core/rpc_dart/lib/src/rpc/streams/bidirectional/**, packages/core/rpc_dart/lib/src/endpoint/responder_pipeline.dart, packages/core/rpc_dart/lib/src/endpoint/caller_pipeline.dart]
status: valid
---

# P-64 — are the two directions of a bidi call independent?

## Why it exists

Round 372 settled bidi's leaks and explicitly left the other half of the owner's
goal — correct handling — to its own bench. Bidi's whole promise is that neither
side waits for the other, so the question is: with one direction idle, finished
or busy, what does the OTHER side observe?

## Measures

Per case, three things: how many payloads the caller received, how the call
ended (`DONE`, an exception type, or `HANG` at a 5 s bound), and — where the
handler records it — how many requests the handler saw.

Cases: the server pushes while the client never sends; the server finishes while
the client holds its request stream open; the server keeps sending after the
client half-closes; and full duplex, 30 messages each way, with ordering
checked.

## Control

**The control is one line of the caller's own code**: the same handler, driven
with `Stream.empty()` instead of a request stream that never closes. It differs
by exactly whether the request stream CLOSES, and it reported `5 DONE` where the
case under test reported `0 HANG`. Nothing else had to be arranged, and it is
what named the mechanism — the trigger is the half-close, not the payload.

The three unaffected cases are a second control: `outlivesHalfClose` (10 DONE)
and full duplex (30 DONE, order preserved) were identical before and after the
fix, so the change is not a blanket "more messages get through".

## The HOP CHECK, and why it is in the probe

A first version reported only what the caller saw, which cannot distinguish *the
responder never heard of this call* from *it answered and the answer was lost*.
The probe therefore samples the server's `openStreams`, `activeResponders` and
`metadataStreams` while the call is in flight. That is L-07 applied, and it paid
immediately: the counters moved 0/0/0 -> 1/0/1 after the first fix, which is how
the SECOND hop was found rather than assumed.

## The numbers (round 373)

```
case                                  caller got   ending   handler saw
server pushes, client never sends        0 -> 5   HANG -> DONE
CONTROL same, client closes at once      5            DONE          (unchanged)
server ends first, client holds open     0 -> 1   HANG -> DONE
server outlives the half-close          10            DONE     3    (unchanged)
full duplex, 30 each way                30            DONE    30    order PRESERVED
```

HOP CHECK: `openStreams/responders/metadataStreams` = 0/0/0 -> 1/0/1 -> call
completes.

## What it establishes, and what it does not

Establishes: the two directions are independent, and a caller that stays silent
still gets a call.

Does not establish ordering under LATENCY — `RpcChannelTransport.pair()`
flattens that (P-58) — nor anything about a caller that sends after the server
has finished, which is B-50's question in the other shape.
