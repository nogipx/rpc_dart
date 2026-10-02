---
round: 651
verdict: FIXED
packages: [rpc_dart]
lens: RPC-19
bench: none — the witness test is the measurement
budget: probes 1/5, canaries 1/5
commit: yes
release: changelog
---

# Round 651 — one flag for every stream

## Target

A previous reviewer's undecided item (round 640's coverage review): a
`UnaryResponder` built directly, listening on its own with `id == 0`, which
serves every stream on its transport.

## Hypothesis

A second request on one stream fails that call and no other.

## Before

```
directly-built UnaryResponder, id 0, one transport
stream 1: request + a second request   status 13 (right: gRPC's rule)
stream 3: request alone                status 13 (wrong: nothing extra was sent)
```

## Control

The pipeline-built responder: it refuses a second request itself, per stream,
and never sets the flag.

## Mechanism

RPC-19, one flag with two scopes. `_tooManyRequests` lived on the responder
while every other piece of per-call state (`_streamStates`, the parser since
an earlier round) is per stream. Set once by any stream -- even one already
answered, since the check runs on frames after `requestHandled` -- it failed
every later stream's answer for good.

## After

The flag is on `_UnaryStreamState`; stream 3 answers 0.

## Canary

A responder-wide flag restored beside the per-stream one: stream 3 reads `13`.

## Gate

Rounds 651-657 together; recorded in round 657.

## Not fixed

Only reachable through the directly-built responder; servers use the
pipeline.

## Links

Lens `../lenses/RPC-19-one-flag-two-lifecycle-meanings.md` — `applied: [..., 651]`.
Test `packages/core/rpc_dart/test/streams/an_extra_request_fails_only_its_own_stream_test.dart`.
