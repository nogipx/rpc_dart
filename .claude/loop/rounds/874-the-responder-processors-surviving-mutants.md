---
round: 874
verdict: CLEAN
packages: [rpc_dart]
lens: RPC-15
bench: none — `tool/mutants/mutants.dart`; the one survivor taken further checked against the full suite
commit: yes
release: none
---

# Round 874 — the responder processor's surviving mutants

## Target

Round 873 found a defect from a surviving mutant; the same detector on
`base_processor_responder.dart`, which rounds 862-863 rely on for
`_responseSendFailure`, against `test/streams`.

## Hypothesis

The lines the stream tests leave free do not change what a peer sees.
Fails if a survivor does.

## Before

```
mutants.dart --file base_processor_responder.dart --tests test/streams --limit 15
  15 of 34 run: 4 killed, 3 timeouts (killed), 8 survived
  :62 :67 :172 :177   response/request encoding (compression) checks
  :113                `if (_trailerSent) return;` deleted (_sendOkTrailerIfNeeded)
  :131                `return;` deleted (transport-closed branch)
  :148                `if (!_isActive) return;` deleted (_handleMessage)
  :356                `_isActive = false` on cancellation -> true
```

## Mechanism

Taken further:

- `:356` survives the full rpc_dart suite (+2237 ~1) as well. A processor
  left active after a cancellation still sends no response (`send` checks
  the token first); `finishSending` could then send an OK trailer, but the
  deadline path has already sent its own through `sendError`
  (`_trailerSent`), and a client cancel leaves no peer to read one.
- `:113` is redundant: `finishSending` returns on `_trailerSent` before it
  calls `_sendOkTrailerIfNeeded`.

Not taken further: the four encoding survivors (compression is tested
outside `test/streams`), `:131` and `:148`.

## After

n/a.

## Canary

n/a — no fix. The 7 killed mutants are the detector's evidence.

## Gate

No change; the mutant was applied by hand and reverted.

## Siblings

—

## Not fixed

`:62 :67 :131 :148 :172 :177` were not run against the full suite; 19
of the file's 34 mutants were not run.

## Links

Lens `../lenses/RPC-15-remeasure-own-record.md`. Rounds
`873-a-failed-stream-leaves-a-reused-context-usable.md`,
`862-a-response-that-cannot-be-sent-ends-the-stream.md`.
