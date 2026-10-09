---
round: 796
verdict: FIXED
packages: [rpc_dart]
lens: RPC-25
bench: P-284 — reused
commit: yes
release: changelog
---

# Round 796 — a response after the answer was a warning

## Target

The one cell round 795 left in P-284: a server stream answered INTERNAL for
a second request keeps a handler yielding for the first, and each yield
after the answer warned "Attempted to send response to closed controller".
Round 791 fixed the same race for client-stream at its responder; this one
sits in `StreamProcessor.send`, shared by every streaming shape. `loop.py
find "Attempted to send response to closed controller"` names only rounds
791 and 795; round 576 (send after the peer closed) is the in-memory
channel, a different layer.

## Hypothesis

A peer that sends a second request on a server stream writes one warning
per call.

## Before

P-284, 200 calls:

```
  s twoMessages   200 warnings  "Attempted to send response to closed controller"
  every other cell  0 (after round 795)
```

Probe: `packages/core/rpc_dart/.dart_tool/probe/warnings_per_peer_call.dart`

## Mechanism

`sendError` closes the response controller; the handler's next yield
reaches `send`, which warned when the controller was closed. That state is
"the call has already been answered", reached ordinarily after any error
answer while the handler still runs.

## After

`send` drops the late response at a guarded internal level. P-284: 0 in all
17 cells (16 shape/input pairs and the unregistered method).

## Canary

`test/logger/a_peer_fault_is_not_an_incident_test.dart`, new case "s: the
handler producing after the answer writes no warning"; with the warning
restored it failed, `Expected: empty Actual: ['Attempted to send response
to closed controller' x10]`, the other 14 cases green.

## The verdict questions

1. Yes: `s twoMessages` against `s complete`, same rig.
2. Yes: 200 against 0.
3. Library side: the responder's `LogController`.
4. The zero after comes from the cell that read 200.
5. Yes, quoted.
6. One half.
7. FIXED.
8. Nothing dismissed by a record.
9. None.
A1. One process; hand-built channel peer.
A2. Volume: calls per connection.
L1. n/a.

## Gate

`fvm dart format` (0 changed), then `melos run analyze` green; `melos run
test:unit --no-select` green (15 packages, rpc_dart +2145 ~1); `melos run
format:check` green; `melos run license:check` green. `fvm dart test -p
node` on the test: 15 of 15.

## Not fixed

Nothing left in P-284. "Attempted to send response on inactive processor"
and "... error on inactive processor" stay warnings: no peer-driven input
measured in rounds 790-796 reaches them after round 791.

## Links

Lens `../lenses/RPC-25-the-same-abstraction-four-times.md`.
Probe `../probes/P-284-log-records-per-malformed-call.md`.
Round `795-a-peers-invalid-input-was-logged-as-our-fault.md`.
Round `791-a-cancelled-client-stream-was-a-warning-per-call.md`.
