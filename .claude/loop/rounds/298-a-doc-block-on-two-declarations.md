---
round: 298
verdict: FIXED
packages: [rpc_dart]
lens: RPC-23
bench: none
commit: yes
---

# Round 298 — a doc block on two declarations

## Target

Six more core files, at the batch unit round 297 established: the highest
remaining by volume (`client_connection`, `caller_pipeline`, `rate_limiter`,
`frame_multiplexed_channel`) plus the two densest (`retry_interceptor` at 55%,
`compression` at 50%).

## Hypothesis

297 raised the unit to a batch and predicted that adjacency defects keep coming
— fused docs, verbatim duplicates, the same measurement twice. If that is a real
property of the corpus rather than a coincidence of two files, this batch should
find more.

## Before

```
                              comments   total   ratio
client_connection                  253     680   37%
caller_pipeline                    249     894   27%
rate_limiter                       228     705   32%
frame_multiplexed_channel          225     607   37%
compression                        111     221   50%
retry_interceptor                  108     194   55%

core/lib total                    6247   23360   26.7%
```

## Mechanism

**The adjacency defect, again, and this one is the clearest yet.** In
`compression.dart`, `_normalize` carried `register`'s ENTIRE doc block —
description, "call this once at application startup", and the
`RpcGrpcCompression.register('gzip', ArchiveGzipCodec());` sample — followed by
its own. `register` then had the same nine lines again, twenty lines further
down. A reader of `_normalize` was told it registers a codec; a reader of the
file saw the same instruction twice and had no way to tell which was current.

That is now three files in three rounds (296 `channel_transport`, 297
`responder_pipeline` and `getMessagesForStream`, 298 `compression`). The shape
is not incidental to any one file.

Two more of the lens's own categories showed up:

- **A measurement contradicting its own conclusion.** `retry_interceptor`'s
  `retryOn` doc admitted, at length, that an earlier version of that same doc had
  been backwards about lost responses — a correction addressed to a reader of the
  previous revision, which nobody now is.
- **API docs bloated by repetition rather than narrative.** `RpcRateLimiter`'s
  74-line class doc carried four constructor samples differing only in which
  argument was set. Cut to one sample plus the two things a caller cannot infer:
  the priority order, and what each call shape costs.

## After

```
                              comments   total
client_connection                  219     646
caller_pipeline                    211     856
rate_limiter                       191     668
frame_multiplexed_channel          193     575
compression                         89     199
retry_interceptor                   78     164

core/lib total                    6054   23167
```

**-193 comment lines.** Core is at **26.1%**, from 27.6% at 297's start and
27.6% measured as the true baseline.

Kept as invariants: the proxy's id watermark, because a fresh transport restarts
at 1 and a dead call's `finishSending(1)` then half-closes a live one; the
`IRpcStreamIdSequence` refusal on EVERY attach, because an `is` check is erased
in silence by a decorator; the buffer cap checked BEFORE the append, because
appending first bounds what is retained and not what is allocated; the inbound
refusal trailer trimmed to `maxHeaderValueBytes`, because a refusal's own answer
must satisfy the rule that refused; `_validate` as a throw rather than an assert,
because Dart strips asserts in release and a zero window silently disables the
limiter; the `decompress` hint as the only bomb defence that acts in time.

## Canary

Analyzer over lib plus the suite. As in 295-297, that shows the code still
compiles and behaves; it cannot witness a comment. Stated rather than implied.

## Gate

`melos run analyze` — SUCCESS over 21 members plus `rpc_dart_wasm`.
`rpc_dart` suite: 1429 passed, 1 skipped, 0 failed.
`fvm dart format` — 92 files, 0 changed.

## Not fixed

Core remains at 26.1%. Largest left: `responder_pipeline` 461,
`channel_transport` 430, `base_processor` 295, `context` 203, `special_cbor`
192, `security_policy` 166, `contract` 164.

Four packages of the mandate are still untouched, in the owner's order:
websocket, http, isolate, http2.

## Links

RPC-23 (`applied:` gains 298). No change to the lens: 297's revision predicted
this batch's findings and needed no amendment, which is the first evidence that
the corrected detector and the adjacency rule are stable.
