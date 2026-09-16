---
status: open
round: 366
commit: b17af71c
paths: [packages/core/rpc_dart/lib/src/core/security_policy.dart, packages/core/rpc_dart/lib/src/rpc/transports/channel_transport.dart]
probe: P-58
reason: a policy default change with a compatibility surface — the owner asks to be consulted before trades of that kind
---

# B-47 — the initial send window is smaller than a message

`RpcSecurityPolicy.initialSendWindowBytes` defaults to **64 KiB**. It arrived in
6.0.0; 5.0.1 had no such parameter at all.

A downstream consumer chunks blobs at **256 KiB** a frame — four times the
window. Measured over a real socket in P-58:

```
frames     6.0.0 defaults   5.0.1 shape
2, 3, 8    parks ~1xRTT     never parks
```

## What the park buys

Nothing that can be named. The data still goes out — a round trip later, once
the peer's first grant lands. The window does not bound the receiver's memory
here, because the sender simply waits and then sends the whole message anyway;
the gate admits on `credit > 0` rather than on whether the message fits, so a
256 KiB frame passes a 64 KiB window and drives the balance negative regardless.

What it does buy is a state that did not exist before: a parked sender on the
second frame of every stream, on any link with a round trip. Round 366 fixed the
defect that lived in that state. The state itself is still there.

## The shape of a fix, and why it is not made here

An initial window smaller than the largest message a caller will send can only
delay it. Candidates: raise the default above any plausible single message;
derive it from `maxMessageSize`; or admit on "does it fit" rather than on
"credit > 0" and let the first message through by definition.

All three change a shipped default's behaviour for every peer, and the config's
standing owner requirement is to ASK before trading behaviour of that kind. The
numbers to decide on are above.

## What would close it

An owner decision, plus a bench showing what the chosen default costs on a link
with a round trip — P-58 is the harness, and it already reports park duration
per policy.

## Owner decision

None yet. What is being asked: whether to change a shipped default — raise it
above any plausible single message, derive it from `maxMessageSize`, or admit on
"does it fit" — accepting that every peer's behaviour changes with it, against
leaving a parked sender on the second frame of every stream over any link with a
round trip. Round 366 fixed the defect that lived in that state; the state
itself is what this lead is about.
