---
round: 734
verdict: CLEAN
packages: [rpc_dart, rpc_dart_http2, rpc_dart_framework]
lens: RPC-02
bench: none — a sweep that names every site; the one uncapped message-carrying site has no reachable observer
commit: yes
release: none
---

# Round 734 — refusal trailers re-swept

## Target

RPC-02, last swept in round 349 over 12 sites: a trailer whose `grpc-message`
breaks the very `maxHeaderValueBytes` the policy enforces, so validation drops
the status and the caller is answered nothing. Refusal paths have been added
since. The detector is mechanical: every `RpcMetadata.forTrailer(` across
core, the transports and the framework.

## Hypothesis

A trailer added after round 349 carries a message with no `maxMessageLength`
cap.

## Before

```
  RpcMetadata.forTrailer( sites                           22
    capped with maxMessageLength                          14
    status only, no message (ok / invalidArgument /
      a bare status)                                       7
    message, uncapped                                      1
```

The uncapped one is `unary/responder.dart:250`, `_dropLateResponse`. Its
message is the call token's cancellation reason. On that path the reason is
set by the pipeline alone: `deadline exceeded`, `server draining` and
`endpoint closed` are fixed, short strings, and the only variable one is the
client's own `x-client-cancelled` reason, sent by a client that has already
cancelled and waits for no trailer.

## Mechanism

No defect: every message a waiting caller could miss is capped.

## After

n/a.

## Canary

n/a — no fix and no bench. The evidence is the sweep: every site is named
above and classified.

## The verdict questions

1. n/a — a sweep, not a measurement.
2. n/a.
3. n/a.
4. The count is mechanical, so a missed site would be visible in the total.
5. n/a.
6. n/a.
7. CLEAN, on a full enumeration rather than a sample (L-12).
8. None.
A1. n/a.
A2. n/a.
L1. n/a.

## Gate

No library change.

## Not fixed

`_dropLateResponse` could take the cap for uniformity. Without an observer
that would notice, that is a change with no evidence behind it, so it was
not made.

## Links

Lens `../lenses/RPC-02-refusal-trailer-violates-policy.md` — `applied: [..., 734]`.
