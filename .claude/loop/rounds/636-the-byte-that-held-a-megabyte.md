---
round: 636
verdict: FIXED
packages: [rpc_dart]
lens: RPC-17
bench: none — the witness reads RSS across 300 packed chunks; the audit's probe gives the numbers
budget: probes 2/5, canaries 1/5
commit: yes
release: changelog
---

# Round 636 — the byte that held a megabyte

## Target

B-229, owner's direction 1: copy a payload out of its chunk when it is queued.

## Hypothesis

A decoded payload is a `sublistView` into the inbound chunk, a queued message
keeps the chunk alive, and every limit charges the payload's length.

## Before

```
one held client-stream; each chunk = a 1-byte request on it + 1 MiB on a closed id
300 chunks   charged ~3000 B   RSS 231 -> 505 MiB   no refusal
same bytes, one frame per chunk: 230 -> 234 MiB
witness: +239 MiB
```

## Control

The split arm: the same bytes, a frame per chunk, hold nothing.

## Mechanism

RPC-17's shape turned inside out: the limit fires on time, but on a number that
is not what is resident. The filler costs the peer nothing, since frames on a
closed id are dropped silently.

## After

`_ownedPayload` copies a payload that is a view into a larger buffer, at the
three places a message WAITS: the pre-bind lists, the pre-method buffer, and
the request sink when its handler is not reading (no listener yet, or paused in
the body of its `await for`). A message handed to a reading handler keeps its
view, so the hot path pays nothing. Probe: `221 -> 198 MiB` with all 300
requests delivered; the witness is green.

## Canary

The before lines are the same witness and probe without the copies.

## Gate

`analyze` and `format` on rpc_dart green, `melos run test:unit` green (exit 0).
`test:web` ran the core suite on node with no failure from this change; its only
reds were round 637's witness, already written and deliberately red, and under
`set -e` that stopped the run before the other suites. Round 637's gate runs
`test:web` in full over this change.

## Not fixed

The caller side's per-stream controllers queue views the same way; the peer
there is the server the caller chose, so it was left.

## Links

Lead `../backlog/B-229-a-tiny-message-pins-its-whole-chunk.md` — closed.
Lens `../lenses/RPC-17-limit-fires-after-residency.md` — `applied: [..., 636]`.
Test `packages/core/rpc_dart/test/transports/a_queued_request_does_not_pin_its_chunk_test.dart`.
