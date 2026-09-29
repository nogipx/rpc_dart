---
file: packages/core/rpc_dart/.dart_tool/probe/b108_ping_ignores_context.dart
round: 499
commit: d5cfdf8a
paths: [packages/core/rpc_dart/lib/src/endpoint/caller_pipeline.dart, packages/core/rpc_dart/lib/src/endpoint/ping.dart]
status: valid
---

# P-137 — does ping() honour its context?

## Why it exists

Ping is the keepalive, so the connection it exists to detect — up, accepting
frames, answering nothing — is exactly the one where an unbounded wait matters.
The bench asks which of the ways a caller can request a bound actually works.

## The harness

A channel pair and a transport decorator that forwards everything EXCEPT a frame
whose `methodPath` is the ping's, which it swallows. Nothing ends that stream, so
only a LOCAL bound can end the wait — which is what makes each arm a statement
about the caller rather than about the peer.

Five arms, one varied thing each: an explicit `timeout:`, a context deadline, a
token cancelled 200 ms INTO the wait, nothing at all, and a peer that answers.
The probe's own budget is 3 s.

## The numbers (round 499)

```
                              before    after
timeout: 200ms                 222ms     217ms   TimeoutException
context deadline 200ms        3003ms     204ms   TimeoutException
token cancelled at 200ms      3002ms     203ms   RpcCancelledException
nothing asked                 3002ms    3004ms   <- correct
CONTROL, a peer that answers    32ms      20ms   ok, rtt sane
```

## Measures

Wall-clock to return, and the exception type. `3003ms` is the probe's budget
rather than a library bound, so any row at 3 s means "nothing here ended the
wait".

## Control

Two, and both are load-bearing in opposite directions:

- **a peer that answers**, which must stay fast and correct — a bound derived
  from the wrong place would show up here as a broken ping.
- **nothing asked**, which must STILL hang. Deriving a bound from the context
  must not invent one where the caller requested none; that is B-107's policy
  question and not this bench's. Without this arm, "everything returns quickly"
  would read as success.

The `timeout: 200ms` arm is the positive control: it is the bound the API
documents, it worked before, and it pins that the new derivation did not displace
it.

## What it establishes, and what it does not

Establishes: the context deadline and the token were not consulted after the
single pre-check at the top of `ping()`, and both now bound the wait.

Does NOT witness the wall-clock RTT or the unlistened-completer race — neither is
drivable from here. The RTT has its own witness in
`ping_honours_its_context_test.dart`, which injects a skewed `sentAt` (an hour in
the past) in place of a clock step and reads `1:00:00.012557` under ablation. The
`.ignore()` is reasoned from the code and unwitnessed.
