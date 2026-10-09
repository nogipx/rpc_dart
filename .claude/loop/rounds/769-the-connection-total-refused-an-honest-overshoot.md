---
round: 769
verdict: FIXED
packages: [rpc_dart]
lens: RPC-01
bench: P-269 — new
commit: yes
release: changelog
---

# Round 769 — the connection total refused an honest overshoot

## Target

Left by round 768: `RpcChannelTransport`'s buffer ledger bounds the
connection total at `flowControlConnectionWindowBytes`, while the sender
admits a message on any remaining credit, as its own doc says. The
per-stream bound already carries one message of slack
(`effectiveStreamBufferBytes`); the connection bound did not. The same
number fed `RpcResponderBufferBudget.connectionBytes`, the other consumer.
L-20's shape: a receiver limit the sender is not paced to.

## Hypothesis

An honest caller that pauses several large-message streams and resumes
them is refused under the default policy.

## Before

P-269, `RESUME=1`, 3 runs each:

```
  default policy, 6 streams x 2 x 15 MB   refused 1 of 6 (3 of 3 runs)
      RpcStatusException(8): Stream 9 buffered past the connection total
      of 67108864 bytes un-consumed without being consumed
  64 KiB window, 1 stream x 50 x 40000    refused 1 (round 768's probe)
```

## Mechanism

The receiver's ledger refused at exactly the window, while an honest
sender can hold the window plus one message. Fix:
`RpcSecurityPolicy.effectiveConnectionBufferBytes`, the window plus one
message plus metadata, used by both the channel ledger and the responder
budget. The message slack is capped at one more window, so a window set far
below the message limit still bounds a peer that ignores it.

## After

```
  default policy, 6 x 2 x 15 MB      refused 0 (3 of 3 runs)
  default policy, 10 x 4 x 15 MB     refused 0
  64 KiB window, 1 x 50 x 40000      refused 0
  64 KiB window, 8 x 20 x 40000      refused 0
```

The hostile bound (`the_connection_total_is_bounded_test.dart`, 8 streams
ignoring the window against a 128 KiB connection window) moved from 128 to
316 retained messages of 1 KiB: twice the window plus metadata, the new
ceiling, which the test now takes from the policy.

## Canary

`packages/core/rpc_dart/test/transports/a_paused_caller_is_not_refused_by_the_connection_total_test.dart`,
3 of 3 green; with the three lib files stashed: `Expected: empty  Actual:
[RpcStatusException(8) ...]`.

## The verdict questions

1. The arms differ in whether the caller resumes, and before/after in the
   bound.
2. Yes: 1 refused against 0.
3. At the caller, as stream errors.
4. n/a.
5. Yes, above.
6. One change used in two places; the responder budget half has no
   witness of its own: its connection total is reached only by a peer
   ignoring the window, which the existing bound test covers.
7. FIXED from the counts.
8. Nothing dismissed.
9. None; L-20 already says it.
A1. One policy on both ends.
A2. Volume.
L1. The refusal named the connection total; the per-stream bounds were
    not near.

## Gate

`melos run analyze`, `format:check`, `check:skills`, `test:unit` green.
The skill's flow-control reference now says what the receiver refuses.

## Not fixed

Under a policy whose connection window is below the message limit, a
single message larger than the window can still be refused; the skill
says to keep the window at least one message.

## Links

Probe `../probes/P-269-what-a-paused-caller-meets-at-the-connection-total.md`.
Round `768-a-message-larger-than-the-window-stalled-the-stream.md`.
Lesson `../lessons/L-20-a-limit-the-sender-cannot-see.md`.
