---
round: 869
verdict: CLEAN
packages: [rpc_dart, rpc_dart_http2]
lens: RPC-02
bench: P-08 — reused
commit: yes
release: none
---

# Round 869 — the refusal trailers, re-swept a third time

## Target

The curate pass after round 868 raised RPC-02: its sweep (round 818) had 36
files move along its paths since, rounds 855-857 among them, which added a
refusal (an http2 request cut mid-message) with a 68-character diagnosis.
The lens asks whether every refusal trailer fits under the cap it was
validated against, and says the next round should ablate, not re-read.

## Hypothesis

Every trailer site with a message still carries the cap, and the new
refusal answers its status at a cap below its text. Fails if a site lacks
the cap, or the refusal loses its status.

## Before

```
sites (each forTrailer( call read to its closing paren): 22
  with a message 17: capped 16, uncapped 1 (_dropLateResponse, round 818's)
  without a message 5

P-08, http2:   cap 8192 / 64: unimplemented 12, un-consumed window 8, plain call ok
               cap 16: confounded, as recorded
P-323 at cap 64, a request cut at 7 bytes, every shape and ending:
  current                         grpc=3, text trimmed
  _answerFramingViolation's cap ablated   grpc=null (no status reaches the client)
```

## Mechanism

None found: the new refusal reuses `_answerFramingViolation`, which caps
its message; no new trailer site appeared.

## After

n/a.

## Canary

n/a — no fix. The ablated row is the bench's control.

## Gate

No library change; the ablation was reverted.

## Siblings

—

## Not fixed

—

## Links

Lens `../lenses/RPC-02-refusal-trailer-violates-policy.md`. Benches
`../probes/P-08-refusal-survives-a-tight-cap.md`,
`../probes/P-323-an-http2-request-cut-mid-message-per-shape-and-ending.md`.
Round `818-the-refusal-trailers-re-swept-again.md`.
