---
round: 798
verdict: FIXED
packages: [rpc_dart]
lens: RPC-19
bench: P-289 — new
commit: yes
release: changelog
---

# Round 798 — data after the half-close read as lost

## Target

A final sweep with P-283 after rounds 787-797, given a new oracle: a hostile
session may write only a handful of warning-or-above records (only
once-per-connection warnings). Checked first that the oracle can see the
class: against round 787's code in a worktree, 26 of 60 sessions failed it;
against today's, 5. Of today's five, handler throws the fuzz provokes on
purpose are genuine faults; the rest were three shapes, taken one per round.
This one first because its record claims DATA LOSS: "Request messages LOST
for Svc.c ... the pipeline accepted 2 and the handler was given 1", beside
"Request message DROPPED". The `minlog` minimiser reduced it to three
frames on one stream.

## Hypothesis

A client-stream peer that sends a message after its own half-close makes
the request-loss alarm fire at ERROR, once per call, for a message that was
correctly dropped.

## Before

P-289, 50 calls:

```
  control   0 records                handler counts {1}
  late      50 "Request messages LOST"   handler counts {0}
```

Probe: `packages/core/rpc_dart/.dart_tool/probe/data_after_half_close.dart`

## Mechanism

`_handleDataMessage` counted every client-stream payload as accepted before
asking anything else; one arriving after `clientEnded` (the half-close came
in the empty DATA frame before it) had no sink to go to, so it was dropped,
and the accepted/delivered comparison at the end of the call reported the
difference as loss. The message was never the call's: the peer had already
ended its request stream. One flag, two meanings (RPC-19): `acceptedRequests`
meant both "frames the peer sent" and "requests the pipeline took".

## After

A client-stream payload after the peer's half-close is ignored at a guarded
internal level and not counted. P-289 `late`: 0 records; `control`
unchanged. The loss detector's own tests
(`a_lost_request_is_named_test.dart`, 12 cases: a healthy upload is
silent, every other ending is silent, the counts agree) are green.

## Canary

`test/streams/data_after_half_close_is_not_a_loss_test.dart`, the
`clientEnded` check ANDed with `false`: the witness failed with ten
"Request messages LOST ... accepted 2 and the handler was given 1" records;
the guard (a message before the half-close is delivered, nothing recorded)
green.

## The verdict questions

1. Yes: `late` and `control` carry the same three frames; only their order
   differs.
2. Yes: 50 against 0.
3. Library side: the responder's own records and the handler's own count.
4. The zero after comes from the arm that read 50.
5. Yes, quoted.
6. One half.
7. FIXED.
8. The other two shapes the sweep found (a corrupt message prefix logged as
   a fault; "Attempted to send error on inactive processor") are rounds 799
   and 800, measured, not dismissed. The DROPPED/LOST alarm's purpose
   (round recorded in its comment: an upload acknowledging 16 of 17) was
   read in code, and the fix keeps it for every payload before the
   half-close.
9. None.
A1. One process; hand-built channel peer.
A2. Volume: calls per connection.
L1. n/a — the evidence is a record count and the handler's count.

## Gate

`fvm dart format` (0 changed), then `melos run analyze` green; `melos run
test:unit --no-select`: the first run, at load average 17, failed
`audit_server_deadline_test` and `rpc_dart_log`'s `stop_during_bind_test`;
each passed 3 of 3 alone, two leftover Autobahn echo servers of round 788
were stopped, and the rerun was green (15 packages, rpc_dart +2147 ~1).
`melos run format:check` green; `melos run license:check` green. `fvm dart
test -p node` on the test: 2 of 2.

## Not fixed

Rounds 799 and 800 (above).

## Links

Lens `../lenses/RPC-19-one-flag-two-lifecycle-meanings.md`.
Probe `../probes/P-289-data-after-a-client-half-close.md`.
Probe `../probes/P-283-the-widened-hostile-peer-fuzz.md`.
Round `797-the-caller-reports-a-broken-server-once-per-call.md`.
