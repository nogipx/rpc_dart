---
round: 267
verdict: FIXED
packages: [rpc_dart]
lens: RPC-15
bench: none
commit: yes
---

# Round 267 — the documentation B-23 was hiding

> **This record covers one long round, not one turn.** The work below was
> narrated in commit messages as "rounds 268-282", which was my own counting and
> not the journal's — a round is one target and one verdict, and this is both.
> The commits are `6cfcf104`, `cb3d133f`, `585f927f`, `4147f0a7` and the B-23
> lead's own history. Numbering turns is what produced the 250-266 gap; this
> record exists so the same mistake does not also hide the work.

## Target

B-23's architecture half, `decided by owner`: six private notes to be moved into
the repository as docs, narrowed by the owner to "inventory first, and a note
that only repeats gets deleted rather than moved".

## Hypothesis

The six duplicate `docs/` and reduce to deletions. That was the inventory's
prediction, made from FILE NAMES.

## Before

```
notes to assess                                    6
predicted: duplicates 5, additions 1
docs/ files mentioning gRPC at all                 8
docs/ files naming any x-rpc-* header              0
docs/architecture.md mentions of the 3-layer types 0
docs/guides/diagnostics.md mentions of LogController 0
```

No bench: the detector is "open the note, grep `docs/`, verify against the
implementation", and the answer is a verdict per note.

## Mechanism

An inventory made from names predicts the SIZE of the work, not its SHAPE. Four
of six verdicts changed on contact with the text, and two documentation defects
were found that had nothing to do with private memory — they were simply never
read against the code.

## After

```
verdicts       additions 2, partial 1, deletions 3
docs shipped   docs/transports/grpc-compat.md          (6cfcf104)
               architecture.md, 3-layer transport stack (585f927f)
               core-concepts.md, RpcPeerEndpoint        (4147f0a7)
docs repaired  guides/diagnostics.md                    (cb3d133f)
retired        rpc_dart_log, core_types, core_design, logger
links repointed 7, across MEMORY.md and 3 notes
```

## Canary

n/a for the documentation itself. The one defect with a hard witness is
`diagnostics.md`: it taught `RpcLogger`, `RpcLogger.setDefaultMinLogLevel`,
`RpcLoggerColors` and `IRpcLoggerFormatter`, and `grep RpcLogger` over
`rpc_dart/lib` and `rpc_dart_log/lib` returns **0 hits**. Code following that
guide does not compile — the failure is the compiler's, not a test's.

## Gate

`melos run license:check` REUSE compliant and `melos run format:check` SUCCESS
on every documentation commit. No library code changed, so the test gate is the
one round 266 ran.

## Not fixed

`grpc_compat`'s Dart-to-Go interop constraint and its round-101 story are not
covered by anything shipped, so that note stays as a partial pointer rather than
a retirement. And `logger`'s claim that the logging API is FROZEN as of 3.2.1
was deliberately not carried over: it is a decision, and if it still holds it
belongs in the repository rather than in private memory.

B-23's other half — the per-subsystem dossiers — is untouched.

## Links

Lead B-23 (architecture half discharged) · lens RPC-15, re-measure your own
record · the rule that made every retirement cost more than a delete is L-09.
