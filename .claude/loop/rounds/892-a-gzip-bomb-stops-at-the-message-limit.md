---
round: 892
verdict: CLEAN
packages: [rpc_dart]
lens: RPC-18
bench: P-344 — new
commit: yes
release: none
---

# Round 892 — a gzip bomb stops at the message limit

## Target

Lens RPC-18 (rank 1) on core: a dependency that holds peer bytes below every
limit we own. Core has no runtime dependencies, so the candidates are SDK
code that peer bytes pass through. The `StreamController` buffers are covered
by the flow-control rounds; this round takes dart:io's zlib, which inflates a
compressed message before `maxMessageLengthBytes` can be read. Records
weighed: round 785 (DEFERRED on B-275, its price re-measured by round 803 at
+105 MiB per 15 KiB request, an accepted default), B-207 (the skipped
`close()`, refuted by measurement in round 591), rounds 620 and 676.

## Hypothesis

`rpcGzipDecompress` lets dart:io inflate much more than `maxOutputBytes`
before its sink reads the size, so a bomb of a few hundred KiB holds a large
multiple of the message limit before the refusal. Fails if the peak is near
the limit.

## Before

P-344:

```
arm      1 GiB of zeros, 1019 KiB wire, max 16 MiB   refused in 5 ms   +15, +16 MiB
control  64 MiB of zeros, 63 KiB wire, no max        decoded 29-37 ms  +123, +125 MiB
```

## Mechanism

n/a (CLEAN). The chunked decoder hands output to `_LimitedByteSink` as it
works, and the sink's throw stops it inside the one `add`: the peak is the
limit plus one zlib output chunk.

Every peer path reaches it with a limit: the only caller is
`RpcMessageParser` (`parser.dart`), which passes `maxOutputBytes:
_maxMessageLength`, through `base_processor.dart`'s decompressor; no transport
calls the codec directly (text sweep of `rpcGzipDecompress` and
`maxOutputBytes` over core and transport `lib/`). The unbounded branch is only
reachable from application code that passes no limit.

## After

No change.

## Canary

n/a (CLEAN). The control is the bench's own: the same meter reads full
residency on the unbounded path.

## Gate

n/a — no code change.

## Siblings

Not per transport: the parser is the one decompression path for every
transport.

## Not fixed

—

## Links

RPC-18, round 785, round 803, B-207, P-344.
