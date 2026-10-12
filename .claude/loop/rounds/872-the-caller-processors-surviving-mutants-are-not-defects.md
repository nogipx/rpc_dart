---
round: 872
verdict: CLEAN
packages: [rpc_dart]
lens: RPC-15
bench: none — `tool/mutants/mutants.dart`, the config's surviving-mutant detector; each survivor then checked against the full suite or a probe
commit: yes
release: none
---

# Round 872 — the caller processor's surviving mutants are not defects

## Target

The config's third class-wide detector, surviving mutants, on the file
rounds 846-863 changed most: `base_processor_caller.dart`. A survivor is
a line no test constrains, a hypothesis for a round. RPC-15 (re-measure
your own record): the rounds that edited this file each wrote a witness;
the mutants ask what those witnesses leave free.

## Hypothesis

Every line the stream tests leave unconstrained is either constrained
elsewhere or cannot change behaviour. Fails if a survivor changes what a
caller or the server sees.

## Before

```
mutants.dart --file base_processor_caller.dart --tests test/streams --limit 15
  15 of 79 run: 7 killed, 3 timeouts (killed), 1 stillborn, 4 survived
  :48   return after a successful stream reset, deleted
  :133  request-stream error forwarded to the response stream, negated
  :534  return after _failIfEndedMidMessage, deleted
  :718  `!_isActive || _initialMetadataSent` -> `&&`
```

## Mechanism

Each survivor, checked:

- `:534` — equivalent: `_failIfEndedMidMessage` has closed the response
  controller, and everything below the return is guarded on `isClosed`.
- `:133` — equivalent: the full rpc_dart suite (+2231 ~1) also passes it.
  Only the deadline and the cancellation add errors to the caller's
  request controller, and both add the same error to the response
  controller directly, so the forwarding is redundant.
- `:48` — the cancellation notice also goes out as metadata after a
  successful reset: a second notice to a stream already reset, no change a
  peer acts on.
- `:718` — probe `.dart_tool/probe/r872_cancelled_before_metadata.dart`, 20 bidi calls
  cancelled in the same turn as their first listen: 0 handlers started,
  with the mutant and without. The cancellation listener runs after the
  queued metadata, so the guard's inactive half is not reached here.

## After

n/a.

## Canary

n/a — no fix. The 7 killed mutants and 3 timeouts are the detector's own
evidence that the tests constrain this file.

## Gate

No change: each mutant was applied by hand and reverted (`git status`
clean but for the journal).

## Siblings

—

## Not fixed

64 of the file's 79 mutants were not run (`--limit 15`).

## Links

Lens `../lenses/RPC-15-remeasure-own-record.md`. Rounds
`846-a-response-cut-mid-message-is-an-error.md`,
`854-a-hostile-response-is-logged-once.md`.
