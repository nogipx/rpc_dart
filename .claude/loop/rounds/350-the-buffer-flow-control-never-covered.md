---
round: 350
verdict: FIXED
packages: [rpc_dart]
lens: RPC-17
bench: P-31 — reused
commit: yes
---

# Round 350 — the buffer flow control never covered

## Target

The owner's, given at the cap: fix B-28. It had sat awaiting a decision since
round 282 because both candidate fixes change behaviour on the path every
channel transport shares.

## Hypothesis

The decision is not a coin toss — one of the two candidates is wrong for a
reason the protocol already states.

## Before

Round 282's measurement, unchanged on this tree:

```
arm       frames offered  sends completed  sender PARKED  connection error
payload              200                8           true              none
metadata            4000             4000          false              none
```

4000 metadata frames, 32 MiB, **none paced and no bound fired**, against a
payload control that parks at exactly the window. The per-stream view from
`getMessagesForStream` is a plain `StreamController`, unweighed and uncapped, so
flow control was the only thing in front of it — and metadata walks past flow
control, deliberately: `sendMetadata` spends no window and `_fcOnConsumed`
returns early on zero bytes.

An unbounded buffer reachable by an unauthenticated peer.

## Mechanism

**Candidate 1, charging metadata against the send window, is wrong.** HTTP/2
applies flow control to DATA only and exempts HEADERS by design, because a
control frame that cannot be sent deadlocks the stream it is trying to end — a
trailer waiting on a window the peer will only open once it sees that trailer.
Pacing metadata would diverge from the protocol this library implements and
introduce that deadlock on every transport at once.

So the answer is candidate 2, and the protocol agrees with it too: headers are
bounded by SIZE (`SETTINGS_MAX_HEADER_LIST_SIZE`), not by the window.

The weigher already existed. `RpcTransportMessage.bufferedBytes` was written in
round 279 and its doc says why it is where it is — *"one home for the rule,
because every transport buffers these and each would otherwise repeat it"*. The
per-stream controller was the one buffer that never asked.

## After

Every frame queued into a per-stream controller is charged against
`effectiveMaxBufferedBytes` and released as the consumer takes it. Over the
bound the STREAM fails with `RESOURCE_EXHAUSTED`; the connection survives.

```
200 metadata frames of ~8 KiB, 256 KiB bound     before      after
errors on the stream                             none        RESOURCE_EXHAUSTED
transport closed                                 no          no
ordinary exchange (default policy)               ok          ok
consumer that KEEPS UP, 200 frames               ok          ok
```

**Failing the stream and not the connection** is the same call the transport
already makes at `closeOnOversizedFrame: !isClient`: a peer flooding one call
must not take down the others sharing the socket.

## Canary

```
the bound ablated   Expected: non-empty
                      Actual: []
                    '200 metadata frames of ~8 KiB against a 256 KiB buffer
                     bound were all accepted'
```

Two GUARDs green in the ablated run, and the second is the one that matters:
**a consumer that keeps up takes all 200 frames with no error.** Without it this
fix could have been a throughput cap wearing a buffer's clothes.

## Gate

`melos run analyze` clean over 21 packages plus `rpc_dart_wasm`; `format:check`
clean; `license:check` green; `test:unit` 14 packages, 0 failures; `test:web`
12 suites plus the chrome step — run because this is core, and core is compiled
for dart2js.

## Not fixed

P-31 does not see this fix, and that is worth recording rather than quietly
re-scoping. It measures the SENDER — frames offered, sends completed, whether
the sender parked — and the bound is on the RECEIVER's buffer. Re-run after the
fix it reports exactly what it reported before: `4000 sends, parked false, no
error`. Both statements are true and they are about different ends.

Worse, its consumer is PAUSED, so it cannot observe an error delivered to that
consumer at all — which is why round 282 read "connection error: none" either
way. The new test resumes before asserting, for exactly that reason.

## Links

RPC-17 — a limit that fires after residency. The purest instance yet: the limit
did not fire at all, and the residency was unbounded.

> **"Which of the two fixes" was not a preference.** The lead framed it as a
> behaviour trade for the owner, and it read like one for 68 rounds. The
> protocol had already answered it: HTTP/2 exempts HEADERS from flow control for
> the deadlock reason, so candidate 1 was never available, and the remaining
> work was to find the weigher — which another round had already written and
> documented as the one home for the rule.
