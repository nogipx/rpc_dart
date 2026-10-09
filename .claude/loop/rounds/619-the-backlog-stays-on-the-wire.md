---
round: 619
verdict: FIXED
packages: [rpc_dart]
lens: RPC-23
bench: P-221 — new
budget: probes 3/5, canaries 0/5
commit: yes
release: none
severity: S3
---

# Round 619 — the backlog stays on the wire

## Target

B-218's two remainders. Item 2: what a window's worth of wire bytes becomes in
memory behind a paused consumer. Item 1's last open part: whether a
client-stream CALLER, whose stream's flow-control state the response's
terminal frame drops, survives an answer that arrives while its upload is
parked on the window.

## Hypothesis

`flowControlWindowBytes`' doc says an expanding codec turns a window of wire
bytes into an "arbitrarily larger backlog", so memory is the window times the
codec's expansion. And an early answer to a parked upload leaves the caller
wedged or holding state.

## Before

```
arm       window    produced   decoded   received   RSS
lean      4096 KiB    4036        2          1      +38 MiB
fat       4096 KiB    4036        2          1      +38 MiB   (16x decoded size)
```

`P-221`. Client-stream caller, 64 KiB window, a handler that reads one message,
stops, and answers 300 ms later: the upload parks at 70 messages, the call
completes with the answer, and the caller's `flowControlStateSizes` returns to
zero. A 300-message upload on the same connection afterwards is served whole.

## Control

The `lean` arm for item 2. For item 1, the follow-up upload on the same
connection, which a wedged pool would refuse.

## Mechanism

The pause stops delivery BELOW the decode, so the standing messages are held as
wire bytes and each is decoded as it is consumed: 2 of 4036. The doc's
multiplication described a consumer the endpoint does not have. For item 1,
`locallyInitiated` is the right branch for the caller: the terminal frame IS the
end of its call, and dropping the state there neither strands the parked sender
nor leaks state.

## After

`flowControlWindowBytes`' doc now says that through an endpoint the standing
backlog is held as wire bytes, and that an expanding codec costs its decoded
size only for what the application keeps. The test header that repeated the old
claim says the same. New witnesses: `the standing backlog is held as wire
bytes, not decoded` (decoded <= received + 1 with a full window and a 16x type),
and `an_early_answer_ends_the_upload_test.dart`.

## Canary

n/a. Item 2 is a documentation fix backed by a measurement, and item 1 changes
no behaviour.

## Gate

The two touched test files (+9) and `lib/src/core/security_policy.dart`
analyzed. The full gate runs with round 617's commit, which this follows.

## Not fixed

Nothing in B-218.

## Links

Lead `../backlog/B-218-the-other-half-closes-are-unmeasured.md` — closed.
Bench `../probes/P-221-what-a-window-becomes.md` — new.
Lens `../lenses/RPC-23-the-narrative-beside-the-code.md` — `applied: [..., 619]`.
Tests `packages/core/rpc_dart/test/transports/the_window_counts_wire_bytes_test.dart`,
`packages/core/rpc_dart/test/transports/an_early_answer_ends_the_upload_test.dart`.
