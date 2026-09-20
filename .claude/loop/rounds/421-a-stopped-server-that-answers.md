---
round: 421
verdict: FIXED
packages: [rpc_dart_http2, rpc_dart_websocket]
lens: RPC-19
bench: none — both are a refusal that accounted for nothing, or answered
  nobody; the evidence is the four existing tests that inverted and two
  ablations
commit: yes
---

# Round 421 — a stopped server that answers

## Target

**B-58 and B-59**, both owner-decided and both about what a server owes a peer
it will not serve.

## Hypothesis

B-58 is a counter increment; B-59 is a mode flag.

B-58 held. **B-59 did not** — the mode flag alone left two real defects, and the
existing suite found both.

## Before

```
B-58  _answerRejectedStream   (refused in HEADERS)  counts, honours the knob
      _answerFramingViolation (refused in a FRAME)  counts nothing, ignores it

B-59  stop() cancels _connectionsSub. The HttpServer underneath is not the
      server's to close, so it keeps accepting and upgrading -- and on the
      broadcast stream the class RECOMMENDS for restartability, an event with
      no listener is simply DROPPED:

          handshake in the gap   accepted
          closed 3 s later       NOTHING
          an RPC over it         HUNG
```

## Mechanism

**B-58's discriminator did not exist until round 412.** This site used to read
`error is RpcException`, which is the BASE of the hierarchy, so a resource limit
and malformed framing matched the same branch — one prefix apart on the wire and
indistinguishable in code. 412 gave them separate statuses (8 and 13), which is
what finally makes "count the protocol violations and not the limits"
expressible.

**B-59's two halves could not both be had without a third state.** Cancelling
protects against a connection landing in `_endpoints` after the clear;
NOT cancelling is the only way to answer the peer. A refusing mode never lets it
land there, so the leak is covered by a different mechanism than the cancel.

## After

`_answerFramingViolation` counts against the 256 backstop and honours
`closeOnProtocolError`, excluding RESOURCE_EXHAUSTED — that peer is not broken,
it is misconfigured, and it is told RESOURCE_EXHAUSTED precisely so it can
correct itself and retry.

`stop()` keeps its subscription and `_handleConnection` refuses an arriving peer
with a close frame. `dispose()` is the new terminal step that releases the
subscription.

### The mode flag alone was wrong twice, and the suite said so

1. **`start()` listened AGAIN.** With the subscription kept, a restart added a
   SECOND listener to a broadcast source — every connection handled twice, two
   endpoints over one channel, and the call failed. `start()` now switches the
   flag back on when a subscription already exists.
2. **Close code 1001 is not sendable.** `package:web_socket` refuses any code
   outside 1000 and 3000-4999, because the reserved ones are the endpoint's own
   to generate. 1001 "going away" is exactly the right MEANING and exactly the
   wrong mechanism; the reason string carries it instead.

Neither was in the decision, and neither would have been found by reading.

## Canary

Four existing tests inverted, which is stronger than a canary written for the
occasion — and **B-59's baseline carried its own inversion instruction**:

> *'if a stopped server now closes what it cannot serve, B-59 is fixed and this
> expectation is the thing to invert'*

```
test                                        before            after
a peer arriving while stopped ...           abandoned         REFUSED
a single-subscription stream restarts       StateError        serves
a failed restart leaves isRunning false     after stop()      after dispose()
the failure says what to do                 after stop()      after dispose()
```

The last two are the honest part: their subject — a throwing listen must not
leave `isRunning` true — is unchanged and still covered. What moved is WHERE the
failure lives, because a restart is no longer the failing operation.

## Gate

```
melos run analyze        SUCCESS, 21 packages + rpc_dart_wasm
melos run test:unit      SUCCESS
melos run format:check   SUCCESS
melos run license:check  compliant
melos run test:web       SUCCESS — dart2js
```

## Not fixed

**B-58 has no new witness of its own.** The counting is exercised by the
existing framing suites staying green; nothing drives 256 malformed frames to
watch the connection close. The sibling site's backstop is tested and this one
now shares its code path, which is an argument rather than a measurement.

**A foreign error on the framing path would COUNT.** `wireStatusFor` redacts
anything that is not ours to INTERNAL, which is not RESOURCE_EXHAUSTED, so it
charges the peer's budget. That means our own bug, 256 times, ends a connection.
Judged acceptable against the alternative — enumerating types again is what
round 412 removed — but it is a real edge and is stated rather than hidden.

**`dispose()` is new public API and nothing calls it.** `RpcApp` goes through
`IRpcServer.stop`, which is correct: a server it may restart must not have its
subscription released. An embedder that never disposes leaks one subscription
per server, which is what `stop()` used to release.

## Links

- B-58, B-59 — both closed here
- round 412 — made B-58's discriminator exist by giving limits and malformed
  framing separate statuses
- round 418 — `IRpcServer.stop({drainTimeout})`, the sibling half of the
  shutdown story
- RPC-19 — `_isRunning` now means "accepting", and `_connectionsSub != null`
  means "attached"; they were one flag
