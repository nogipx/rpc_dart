---
round: 515
verdict: INCONCLUSIVE
packages: [rpc_dart]
lens: RPC-23
bench: none — the rig never reached the site it was aimed at
commit: yes
---

# Round 515 — the rig never reached the warning

## Target

Peer-triggered warnings firing per frame — thirty-first in the audit's rank.

Lens RPC-23, the narrative-beside-the-code lens, pointed at a rule rather than a
comment: `CLAUDE.md` states that a warning a peer can trigger repeatedly must fire
ONCE, behind a bool, and lists five sites that do not.

## Hypothesis

10 000 no-op frames on unknown stream ids produce 10 000 warnings.

## Before

```
10000 no-op frames on unknown stream ids produced:
  (no warnings or errors at all)
```

**Three attempts, all zero, and the claim is therefore UNVERIFIED rather than
refuted.** The frames do not reach `_processResponderMessage` at all — not even its
first branch, which warns when the endpoint is not started and is the most trivially
reachable of the five sites. Something drops a hand-built metadata-only frame before
the pipeline, and this round did not establish what.

Rig: `packages/core/rpc_dart/.dart_tool/probe/b124_peer_warning_flood.dart`

What the reading says should happen: `_opensOrAdvancesStream` returns false for a
metadata-only frame with no `methodPath`, not end-of-stream, no payload and no
`x-client-cancelled` header — so the warning at `responder_pipeline.dart:739` should
fire once per frame. It does not fire at all, so the frame is gone before that.

## Mechanism

Not established. Candidates not eliminated: the channel's `_validateInbound`
rejecting the metadata against the security policy and dropping the frame; the
transport declining to route a metadata-only frame with no known stream; or the
responder pipeline never subscribing in the configuration the rig built.

## After

Nothing. `lib/` is untouched.

## Canary

n/a — nothing was fixed. **And that is the point of recording this as inconclusive:
with no witness there is nothing to switch off, so a "fix" here would be five
one-shot bools with no evidence that any of them changes an observable.**

## Gate

Not run: nothing in `lib/` or `test/` changed.

## What the round DID establish

**`CLAUDE.md`'s prescribed way of testing log guards does not survive a derived
scope, and that is verified.** The guidance says to count calls into a `LogScope`
subclass, because a filtered record cannot be seen from the record stream. But:

```dart
LogScope child(String childName, {String? tag}) {
  return LogScope(_controller, '$name.$childName', ...);
}
```

`child()` constructs a plain `LogScope`, so every override is lost the moment the code
under test derives a scope — which is what `UnaryCaller`, `StreamProcessor` and
`CallProcessor` all do. The first version of this rig counted zero for exactly that
reason before the input was ever in doubt.

The worked example the guidance cites, `flow_controller_logging_test.dart`, works
because the flow controller is handed its scope directly and never calls `child()`.
So the pattern is correct for that shape and silently useless for the common one.

Counting at the controller — overriding `LogController.add` — is the form that
survives, and it keeps the property the guidance wanted: `add` runs before filtering,
so it still answers "did the code decide to log" rather than "was a record
delivered".

## Not fixed

**All five listed warning sites, and both double-logging sites.** Unverified, so
untouched: `responder_pipeline.dart:709, 739, 805` and the two the lead numbers at
1049 and 1256, plus `base_processor.dart`'s `sendError` logging every status at error
and `unary/caller.dart` logging a failed call at error twice.

The double-logging half is the more likely to be real, because it needs no
peer-reachability argument at all — an application NOT_FOUND reading as an incident on
both sides is a matter of levels, not of flooding. A round could confirm it by driving
one failing call and counting. That is the cheaper half and should be taken first.

## Links

Lens RPC-23. Lead B-124 (open, with the reachability problem recorded). The
`LogScope.child` finding belongs to `CLAUDE.md`'s logging section and to
`flow_controller_logging_test.dart` as its cited example.
