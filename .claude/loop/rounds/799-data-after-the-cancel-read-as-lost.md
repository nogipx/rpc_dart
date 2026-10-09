---
round: 799
verdict: FIXED
packages: [rpc_dart]
lens: RPC-19
bench: P-290 — new
commit: yes
release: changelog
severity: S3
---

# Round 799 — data after the cancel read as lost

## Target

The second shape P-283's log oracle left after round 798 (seed 11, 60
sessions, mode `full`: 2 sessions over the oracle). Session 39 wrote
"Request message DROPPED for Svc.c" and "Request messages LOST ... accepted 2
and the handler was given 1" beside "Attempted to send error on inactive
processor". Taken first because, like round 798's, it claims data loss at
ERROR. Session 10 (a corrupt message prefix logged as a fault) and the
inactive-processor warning stay for the next rounds.

Class count before the fix, over every `_cleanupStream` caller in
`responder_pipeline.dart`: refusals and the deadline go through
`_sendGrpcErrorAndCleanup`, which adds the id to the closed set before its
first await; zero-copy refusal does the same; abort and close are
connection-level and stop inbound frames. The one path a peer starts that
ends a stream after an await, without remembering the id first, is
`_handleClientCancellation`. One site.

## Hypothesis

A client-stream peer that cancels and then sends one more frame (its
half-close or a message) gets two ERROR records per call, because the frame
lands between the cancel and the stream's cleanup.

## Before

P-290, 50 calls per arm:

```
  arm         DROPPED   LOST   inactive-processor warning
  control     0         0      0
  cancel      50        50     50
  cancelMsg   50        50     50
  cancelGap   0         0      50
```

Probe: `packages/core/rpc_dart/.dart_tool/probe/data_after_client_cancel.dart`

## Mechanism

`_handleClientCancellation` trips the token, awaits `_closeResponder`, then
awaits `_cleanupStream`, which is where the id joins `_respClosedStreams`.
Closing the responder cancels the handler's request subscription, and
`onCancel` detaches the request sink. A frame arriving during those awaits
still finds the stream state: `_handleDataMessage` counts it as accepted,
finds a bound responder with no sink, logs DROPPED, and the cleanup's
accepted/delivered comparison logs LOST. The frame was never the call's;
the peer had already cancelled it. RPC-19: the stream state meant both "a
live call" and "a call being torn down".

## After

The id is remembered synchronously at the top of
`_handleClientCancellation`, as `_sendGrpcErrorAndCleanup` already does, so
a trailing frame stops at the closed-stream guard. P-290: DROPPED and LOST 0
in `cancel` and `cancelMsg`; `control` unchanged. P-283 seed 11, 60
sessions, `full`: 1 session over the oracle (was 2); session 39 is gone,
session 10 remains.

## Canary

`test/streams/data_after_client_cancel_is_not_a_loss_test.dart`, with the
new `_rememberClosedStream(state.id)` commented out: both witnesses (`a
half-close after the cancel`, `a message after the cancel`) failed with
twenty records each, e.g. "Request message DROPPED for Svc.c [streamId: 1]:
the responder is bound but its request sink is gone, so the message was
neither buffered nor delivered (payload: 0 bytes, endOfStream: true)" and
"Request messages LOST for Svc.c [streamId: 1]: the pipeline accepted 2 and
the handler was given 1 — 1 never arrived (dropped: 1)". The guard (the id,
reused after the cancel, opens a new call answered with status 0) green on
both sides. Restored: 3 of 3.

## The verdict questions

1. Yes: `cancel` and `cancelGap` differ only in whether the trailing frame
   meets the window; `control` ends the same call with a half-close.
2. Yes: 50 and 50 against 0.
3. Library side: the responder's own records.
4. The zero after comes from the arms that read 50.
5. Yes, quoted.
6. One half.
7. FIXED.
8. Session 10 and the inactive-processor warning were measured (P-283 and
   P-290 `cancelGap`), not dismissed; they are rounds 800 and 801.
9. None.
A1. One process; hand-built channel peer.
A2. Volume: a frame inside an await, no latency needed.
L1. n/a — the evidence is a record count.

## Gate

`fvm dart format` (1 changed, the test), then `melos run analyze` green;
`melos run test:unit --no-select` green (rpc_dart +2162 ~1); `melos run
format:check` green; `melos run license:check` green. `fvm dart test -p
node` on the test: 3 of 3.

## Not fixed

The inactive-processor warning: P-290 `cancelGap` writes one per cancelled
client-stream call with no trailing frame at all, so an honest cancel
triggers it. Round 800. P-283 session 10 (a corrupt message prefix logged
as "Request handling failed" and "Internal server error"). Round 801.

## Links

Lens `../lenses/RPC-19-one-flag-two-lifecycle-meanings.md`.
Probe `../probes/P-290-data-after-a-client-cancel.md`.
Probe `../probes/P-283-the-widened-hostile-peer-fuzz.md`.
Round `798-data-after-the-half-close-read-as-lost.md`.
