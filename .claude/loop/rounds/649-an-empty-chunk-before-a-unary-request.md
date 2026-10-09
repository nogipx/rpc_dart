---
round: 649
verdict: FIXED
packages: [rpc_dart]
lens: RPC-25
bench: none — the witness test is the measurement; the coverage-review probe is cov_streams_raw.dart
budget: probes 1/5, canaries 1/5
commit: yes
release: changelog
severity: S2
---

# Round 649 — an empty chunk before a unary request

## Target

A coverage-review finding (round 640): the "no messages and no partial frame"
branch of `UnaryResponder`.

## Hypothesis

The four shapes answer the same frame sequence the same way.

## Before

```
empty DATA chunk, then a valid request
unary    [HEADERS, TRAILER(13 Failed to extract message from payload)]   handler []
server   [HEADERS, DATA, TRAILER(0)]                                      handler [s:a]
bidi     [HEADERS, DATA, TRAILER(0)]                                      handler [b:a]
```

## Control

The request alone: unary answers 0.

## Mechanism

RPC-25: siblings answering one question differently. Every refusal inside the
parser throws, so "no messages, nothing held" could only mean an empty chunk,
and unary treated it as a malformed request while the streaming shapes skip
it. Reachable on channel transports; http2's own parser absorbs empty chunks.

## After

An empty chunk waits like a partial frame: unary answers 0 with handler
`[a]`. An empty chunk with end-of-stream and no request is still refused,
once (GUARD arm).

## Canary

The empty-chunk clause removed: the witness reads `13`.

## Gate

Recorded in round 650.

## Not fixed

Server-stream ignoring a malformed frame AFTER its request (the reviewer's
fourth streams item) is left: a valid second frame there already fails the
call, and whether a malformed one should is a consistency question, not a
lost answer.

## Links

Lens `../lenses/RPC-25-the-same-abstraction-four-times.md` — `applied: [..., 649]`.
Test `packages/core/rpc_dart/test/streams/unary_waits_past_an_empty_chunk_test.dart`.
