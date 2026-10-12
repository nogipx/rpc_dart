---
round: 875
verdict: CLEAN
packages: [rpc_dart]
lens: RPC-15
bench: none — `tool/mutants/mutants.dart`; each survivor taken further against a witness written for it
commit: yes
release: none
---

# Round 875 — the unary caller's send-failure guard gets a witness

## Target

The surviving-mutant detector on `unary/caller.dart` (round 853 changed
it), against `test/streams` and `test/endpoint`.

## Hypothesis

The lines those tests leave free are either held elsewhere or change
nothing a caller sees. Fails if a survivor changes how a call ends.

## Before

```
mutants.dart --file unary/caller.dart --tests test/streams,test/endpoint --limit 10
  10 of 49 run: 2 killed, 2 stillborn, 6 survived
  :228  `if (completer.isCompleted) return;` deleted (tooManyResponses)
  :264  zero-copy decode failure guard negated
  :294  `break` after a second response deleted
  :332  grpc-encoding read negated
  :481  transfer-mode check negated
  :574  `if (!completer.isCompleted) completeError` (a failed request send) negated
```

## Mechanism

Taken further with a new test,
`packages/core/rpc_dart/test/streams/a_unary_call_survives_a_late_or_failed_frame_test.dart`:

- `:574` — a channel whose DATA sends throw. Current code: the call fails
  with the send's error at once. The mutant: `HUNG` at 3 s, the call left
  to a deadline it does not have. A guard nothing held; it now has a
  witness.
- `:228` — data arriving after a status that completed the call: green
  with and without the guard, because `call()` drops its subscription once
  it completes. Kept as a GUARD row.

Not taken further: `:264` and `:481` (zero-copy, tested in
`test/zero_copy`), `:294` (round 637's C-60 records the `break` as
deliberate), `:332` (compression).

## After

n/a.

## Canary

`:574`'s mutant: `Expected: not 'HUNG' Actual: 'HUNG'`; restored: green.

## Gate

`melos run analyze` SUCCESS; `melos run test:unit --no-select` SUCCESS
(rpc_dart +2239 ~1, http2 +358, http +261, websocket +331, isolate +102,
conformance +513 ~149); `format:check` SUCCESS; `license:check` compliant.

## Siblings

—

## Not fixed

39 of the file's 49 mutants were not run.

## Links

Lens `../lenses/RPC-15-remeasure-own-record.md`. Rounds
`853-a-unary-response-with-trailing-bytes-is-an-error.md`,
`873-a-failed-stream-leaves-a-reused-context-usable.md`.
