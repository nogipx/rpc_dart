---
round: 797
verdict: CLEAN
packages: [rpc_dart]
lens: RPC-22
bench: P-288 — new
commit: yes
release: none
---

# Round 797 — the caller reports a broken server once per call

## Target

U-14, the sibling of rounds 790-796: the caller side of the same inputs. A
hostile server answers every unary call with an over-limit response, two
responses, or an undecodable one; does the caller write records the server
chooses the count of?

## Hypothesis

The caller writes log records per answer in a way the server controls
beyond the calls the application made.

## Before

P-288, 100 calls each:

```
  complete       0
  oversized      100 (one per failed call)
  twoResponses   100 (one per failed call)
  badCbor        200 (two per failed call)
```

Probe: `packages/core/rpc_dart/.dart_tool/probe/caller_records_per_hostile_answer.dart`

## Mechanism

None that the server controls: each record follows a call the application
made and failed, and the count equals the calls. C-72 records why that is
correct reporting on the caller and why the server side was not.

## After

n/a.

## Canary

n/a.

## The verdict questions

1. Yes: each arm against `complete`, same caller and server shape.
2. The bench sees records (100-200) where they exist, so it is not blind.
3. Library side: the caller's `LogController`.
4. n/a.
5. n/a.
6. n/a.
7. CLEAN: the hypothesis (a server-chosen count) failed; the per-call
   records are bounded by the application's own calls.
8. The duplicate record for an undecodable response is kept as a known
   item below the bar (C-72), named, not dismissed by a record.
9. None.
A1. One process; hand-built server channel.
A2. Volume: calls.
L1. n/a.

## Gate

n/a — no code change.

## Not fixed

The duplicate caller record for an undecodable response, below the bar.

## Links

Lens `../lenses/RPC-22-the-refusal-path-is-reachable-by-anyone.md`.
Probe `../probes/P-288-caller-records-per-hostile-answer.md`.
Negative `../checked/C-72-a-hostile-server-costs-the-caller-one-record-per-call.md`.
Round `796-a-response-after-the-answer-was-a-warning.md`.
